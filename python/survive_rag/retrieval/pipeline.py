"""The retriever: query in, ranked units and expanded parents out.

Stages, in order:

    1. **Legs**   -- BM25 literal, BM25 expanded, and cosine over embeddings.
    2. **Fusion** -- RRF merges the leg rankings without score normalisation,
       which is what lets a cosine in [0,1] and a BM25 score in [0,30] be
       combined at all.
    3. **Rerank** -- heuristic features refine the fused top-N.
    4. **MMR**    -- diversify so the model sees do *and* don't, not four don'ts.
    5. **Expand** -- units carry their parent section, under a token budget.

Retrieval runs at ``config.granularity`` but every result still resolves to a
child id for the citation, so scoring size and citation size are independent.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

from ..config import RetrievalConfig
from ..corpus.models import Corpus, ParentChunk
from .bm25 import BM25Index, build_index
from .expansion import expand, is_transliterated
from .fusion import reciprocal_rank_fusion
from .rerank import RerankWeights, mmr_select, score_chunk
from .tokenizer import index_terms, tokenize


@dataclass(frozen=True, slots=True)
class RetrievedChunk:
    """One result: the matched unit plus the context handed to the model."""

    unit: Any
    rank: int
    score: float
    context: str
    citation: str
    parent: ParentChunk | None = None

    @property
    def unit_id(self) -> str:
        """Id of the retrieved unit, at whatever granularity was scored."""
        return self.unit.chunk_id


@dataclass(slots=True)
class Retriever:
    """A configured retrieval pipeline bound to one chunked corpus."""

    corpus: Corpus
    config: RetrievalConfig = field(default_factory=RetrievalConfig)
    weights: RerankWeights = field(default_factory=RerankWeights)
    _units: list = field(init=False, repr=False, default_factory=list)
    _index: BM25Index = field(init=False, repr=False, default=None)
    _dense: Any = field(init=False, repr=False, default=None)
    _vocabulary: frozenset[str] = field(
        init=False, repr=False, default_factory=frozenset
    )

    def __post_init__(self) -> None:
        self._units = self.corpus.units(self.config.granularity)
        indexed = [(u.chunk_id, self._doc_terms(u)) for u in self._units]
        self._index = build_index(indexed)
        self._vocabulary = frozenset(t for _, terms in indexed for t in terms)
        if self.config.use_dense_leg:
            self._dense = self._build_dense()

    def _build_dense(self) -> Any:
        """Embed every unit, reusing the on-disk vector cache."""
        from .dense import build_dense_index
        from .embedder import load_embedder

        embedder = load_embedder(
            self.config.embed_model,
            backend=self.config.embed_backend,
            truncate_dim=self.config.embed_dim,
        )
        return build_dense_index(self._units, embedder)

    def _doc_terms(self, chunk: Any) -> list[str]:
        """Terms for one unit, with heading text repeated as a field weight.

        With ``index_parent_terms`` the unit also carries its parent section's
        vocabulary, so a 25-token prohibition is still findable by a query that
        words the situation the way its section does.
        """
        terms = index_terms(chunk.text)
        terms += index_terms(chunk.heading_path) * self.config.heading_boost
        if self.config.index_parent_terms:
            parent = self.corpus.parent(getattr(chunk, "parent_id", ""))
            if parent is not None and parent.chunk_id != chunk.chunk_id:
                terms += index_terms(parent.text)
        return terms

    def _legs(self, query: str) -> tuple[list[list[str]], list[float]]:
        """Run the enabled retrieval legs, returning rankings and RRF weights."""
        cfg = self.config
        rankings: list[list[str]] = []
        weights: list[float] = []

        literal = tokenize(query)
        if cfg.use_literal_leg and literal:
            hits = self._index.search(
                [t for w in literal for t in _stems(w)], limit=cfg.leg_limit
            )
            rankings.append([doc for doc, _ in hits])
            weights.append(cfg.literal_weight)

        if cfg.use_expanded_leg:
            added = expand(query, max_expansions=cfg.max_expansions)
            if added:
                terms = [t for w in literal + added for t in _stems(w)]
                hits = self._index.search(terms, limit=cfg.leg_limit)
                rankings.append([doc for doc, _ in hits])
                weights.append(cfg.expanded_weight)

        if self._dense is not None:
            hits = self._dense.search(query, limit=cfg.leg_limit)
            weight = cfg.dense_weight
            if is_transliterated(query, self._vocabulary):
                weight *= cfg.transliterated_dense_weight
            if weight > 0:
                rankings.append([doc for doc, _ in hits])
                weights.append(weight)

        return rankings, weights

    def retrieve(
        self, query: str, *, topic_hint: str | None = None, top_k: int | None = None
    ) -> list[RetrievedChunk]:
        """Retrieve the best units for ``query``.

        Args:
            query: Raw user query, in English, Hindi transliteration, or both.
            topic_hint: Topic key to bias toward, e.g. when the user asked from
                inside a specific guide.
            top_k: Override the configured result count.

        Returns:
            Results ranked best first, at most ``top_k`` of them.
        """
        cfg = self.config
        k = top_k or cfg.top_k
        rankings, leg_weights = self._legs(query)
        if not rankings:
            return []

        fused = reciprocal_rank_fusion(rankings, k=cfg.rrf_k, weights=leg_weights)
        if not cfg.rerank:
            picked = [(self.corpus.unit(uid), s) for uid, s in fused[:k]]
            keep = [(u, s) for u, s in picked if u is not None]
            return self._materialise([u for u, _ in keep], [s for _, s in keep], query)

        scored: list[tuple[Any, float]] = []
        for rank, (unit_id, _) in enumerate(fused[: cfg.rerank_depth], start=1):
            unit = self.corpus.unit(unit_id)
            if unit is None:
                continue
            scored.append(
                (
                    unit,
                    score_chunk(
                        unit,
                        query=query,
                        fused_rank=rank,
                        topic_hint=topic_hint,
                        weights=self.weights,
                    ),
                )
            )
        scored.sort(key=lambda cs: (-cs[1], cs[0].chunk_id))
        by_id = {u.chunk_id: s for u, s in scored}
        selected = mmr_select(scored, k=k, lambda_=cfg.mmr_lambda)
        return self._materialise(
            selected, [by_id[u.chunk_id] for u in selected], query
        )

    def retrieve_ids(self, query: str, *, top_k: int | None = None) -> list[str]:
        """Ranked unit ids -- what the model's context is built from."""
        return [r.unit_id for r in self.retrieve(query, top_k=top_k)]

    def retrieve_citations(self, query: str, *, top_k: int | None = None) -> list[str]:
        """Ranked child ids -- what a user actually clicks.

        Scored separately from :meth:`retrieve_ids` because a coarse unit wins
        span-overlap recall trivially (it contains more lines), while still
        having to pick the right child out of several to cite correctly.
        Comparing granularities on unit recall alone would flatter the coarse
        ones; this is the apples-to-apples number.
        """
        return [r.citation for r in self.retrieve(query, top_k=top_k)]

    def _materialise(
        self, units: list, scores: list[float], query: str
    ) -> list[RetrievedChunk]:
        """Attach parent context, a token-budget fallback, and a citation."""
        cfg = self.config
        out: list[RetrievedChunk] = []
        for i, (unit, score) in enumerate(zip(units, scores, strict=True), start=1):
            parent = self.corpus.parent_of(unit.chunk_id)
            fits = (
                cfg.expand_to_parents
                and parent is not None
                and parent.token_estimate <= cfg.max_parent_tokens
            )
            out.append(
                RetrievedChunk(
                    unit=unit,
                    rank=i,
                    score=score,
                    context=parent.text if fits and parent else unit.text,
                    citation=self._citation_for(unit, query),
                    parent=parent,
                )
            )
        return out

    def _citation_for(self, unit: Any, query: str) -> str:
        """Pick the child a citation should link to for a retrieved unit.

        A passage or parent covers several children, so the link points at the
        one sharing the most query terms rather than simply the first -- the
        user must land on the sentence that answered them.
        """
        kids = [self.corpus.child(c) for c in getattr(unit, "child_ids", ())]
        kids = [c for c in kids if c is not None]
        if not kids:
            return unit.chunk_id
        terms = set(index_terms(query))
        return max(
            kids, key=lambda c: len(terms & set(index_terms(c.text)))
        ).chunk_id


def _stems(word: str) -> list[str]:
    """Local import shim so the module reads top-down without a cycle."""
    from .tokenizer import stem_candidates

    return stem_candidates(word)
