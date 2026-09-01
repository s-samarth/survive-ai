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
from ..corpus.models import Corpus
from .bm25 import BM25Index, build_index
from .citations import CitationPicker, build_picker
from .expansion import expand, is_transliterated
from .fusion import reciprocal_rank_fusion
from .rerank import RerankWeights, mmr_select, score_chunk
from .results import RetrievedChunk, materialise
from .tokenizer import index_terms, tokenize


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
    _picker: CitationPicker = field(init=False, repr=False, default=None)

    def __post_init__(self) -> None:
        self._units = self.corpus.units(self.config.granularity)
        indexed = [(u.chunk_id, self._doc_terms(u)) for u in self._units]
        self._index = build_index(indexed)
        self._vocabulary = frozenset(t for _, terms in indexed for t in terms)
        if self.config.use_dense_leg:
            self._dense = self._build_dense()
        self._picker = build_picker(self.corpus, self.config)

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
            return self._results([u for u, _ in keep], [s for _, s in keep], query)

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
        return self._results(selected, [by_id[u.chunk_id] for u in selected], query)

    def _results(
        self, units: list, scores: list[float], query: str
    ) -> list[RetrievedChunk]:
        """Assemble results with context, citation and rank."""
        return materialise(
            units,
            scores,
            query,
            corpus=self.corpus,
            config=self.config,
            picker=self._picker,
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
        k = top_k or self.config.top_k
        return self.citations_for(self.retrieve(query, top_k=k), query, limit=k)

    def citations_for(
        self, hits: list[RetrievedChunk], query: str, *, limit: int = 5
    ) -> list[str]:
        """Rank the children covered by ``hits`` as a citation list."""
        return self._picker.rank([h.unit for h in hits], query, limit=limit)


def _stems(word: str) -> list[str]:
    """Local import shim so the module reads top-down without a cycle."""
    from .tokenizer import stem_candidates

    return stem_candidates(word)
