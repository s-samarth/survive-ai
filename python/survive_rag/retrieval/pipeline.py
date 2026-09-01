"""The retriever: query in, ranked children and expanded parents out.

Stages, in order:

    1. **Legs**   -- BM25 over the literal query, BM25 over the expanded query.
    2. **Fusion** -- RRF merges the leg rankings without score normalisation.
    3. **Rerank** -- heuristic features refine the fused top-N.
    4. **MMR**    -- diversify so the model sees do *and* don't, not four don'ts.
    5. **Expand** -- children carry their parent section, under a token budget.

Only step 5 is about generation; steps 1-4 are what the retrieval eval scores.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from ..config import RetrievalConfig
from ..corpus.models import ChildChunk, Corpus, ParentChunk
from .bm25 import BM25Index, build_index
from .expansion import expand
from .fusion import reciprocal_rank_fusion
from .rerank import RerankWeights, mmr_select, score_chunk
from .tokenizer import index_terms, tokenize


@dataclass(frozen=True, slots=True)
class RetrievedChunk:
    """One result: the matched child plus the context handed to the model."""

    child: ChildChunk
    rank: int
    score: float
    context: str
    parent: ParentChunk | None = None

    @property
    def citation(self) -> str:
        """The stable id a user-facing citation links to."""
        return self.child.chunk_id


@dataclass(slots=True)
class Retriever:
    """A configured retrieval pipeline bound to one chunked corpus."""

    corpus: Corpus
    config: RetrievalConfig = field(default_factory=RetrievalConfig)
    weights: RerankWeights = field(default_factory=RerankWeights)
    _index: BM25Index = field(init=False, repr=False)

    def __post_init__(self) -> None:
        self._index = build_index(
            [(c.chunk_id, self._doc_terms(c)) for c in self.corpus.children]
        )

    def _doc_terms(self, chunk: ChildChunk) -> list[str]:
        """Terms for one child, with heading text repeated as a field weight.

        With ``index_parent_terms`` the child also carries its parent section's
        vocabulary at low weight, so a 25-token prohibition is still findable
        by a query that words the situation the way its section does.
        """
        terms = index_terms(chunk.text)
        terms += index_terms(chunk.heading_path) * self.config.heading_boost
        if self.config.index_parent_terms:
            parent = self.corpus.parent(chunk.parent_id)
            if parent is not None:
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

        return rankings, weights

    def retrieve(
        self, query: str, *, topic_hint: str | None = None, top_k: int | None = None
    ) -> list[RetrievedChunk]:
        """Retrieve the best chunks for ``query``.

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
            picked = [self.corpus.child(cid) for cid, _ in fused[:k]]
            scores = [s for _, s in fused[:k]]
            return self._materialise([p for p in picked if p], scores)

        candidates = fused[: cfg.rerank_depth]
        scored: list[tuple[ChildChunk, float]] = []
        for rank, (chunk_id, _) in enumerate(candidates, start=1):
            chunk = self.corpus.child(chunk_id)
            if chunk is None:
                continue
            scored.append(
                (
                    chunk,
                    score_chunk(
                        chunk,
                        query=query,
                        fused_rank=rank,
                        topic_hint=topic_hint,
                        weights=self.weights,
                    ),
                )
            )
        scored.sort(key=lambda cs: (-cs[1], cs[0].chunk_id))
        by_id = dict(scored)
        selected = mmr_select(scored, k=k, lambda_=cfg.mmr_lambda)
        return self._materialise(selected, [by_id[c] for c in selected])

    def retrieve_ids(self, query: str, *, top_k: int | None = None) -> list[str]:
        """Return only the ranked chunk ids -- the form the metrics consume."""
        return [r.child.chunk_id for r in self.retrieve(query, top_k=top_k)]

    def _materialise(
        self, chunks: list[ChildChunk], scores: list[float]
    ) -> list[RetrievedChunk]:
        """Attach parent context and a token-budget fallback to each result."""
        cfg = self.config
        out: list[RetrievedChunk] = []
        for i, (chunk, score) in enumerate(zip(chunks, scores, strict=True), start=1):
            parent = self.corpus.parent_of(chunk.chunk_id)
            fits = (
                cfg.expand_to_parents
                and parent is not None
                and parent.token_estimate <= cfg.max_parent_tokens
            )
            out.append(
                RetrievedChunk(
                    child=chunk,
                    rank=i,
                    score=score,
                    context=parent.text if fits and parent else chunk.text,
                    parent=parent,
                )
            )
        return out


def _stems(word: str) -> list[str]:
    """Local import shim so the module reads top-down without a cycle."""
    from .tokenizer import stem_candidates

    return stem_candidates(word)
