"""The retriever: query in, ranked units and expanded parents out.

Stages, in order:

    1. **Legs**   -- BM25 literal, BM25 expanded, and cosine over embeddings.
    2. **Fusion** -- RRF merges the rankings without score normalisation, which
       is what lets a cosine in [0,1] and a BM25 score in [0,30] combine.
    3. **Rerank** -- heuristic features refine the fused top-N.
    4. **MMR**    -- diversify so the model sees do *and* don't.
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
from .expansion import is_transliterated
from .fusion import reciprocal_rank_fusion
from .legs import run_legs
from .rerank import RerankWeights, mmr_select, score_chunk
from .results import RetrievedChunk, materialise
from .tokenizer import index_terms


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

    @property
    def vocabulary(self) -> frozenset[str]:
        """Every term indexed from the corpus; used to spot bridge words."""
        return self._vocabulary

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
        """Terms for one unit, heading text repeated as a field weight.

        ``index_parent_terms`` additionally lends the parent's vocabulary, so a
        short prohibition is findable by a query worded as its section is.
        """
        terms = index_terms(chunk.text)
        terms += index_terms(chunk.heading_path) * self.config.heading_boost
        if self.config.index_parent_terms:
            parent = self.corpus.parent(getattr(chunk, "parent_id", ""))
            if parent is not None and parent.chunk_id != chunk.chunk_id:
                terms += index_terms(parent.text)
        return terms

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
        rankings, leg_weights = run_legs(
            query,
            cfg=cfg,
            index=self._index,
            dense=self._dense,
            vocabulary=self._vocabulary,
        )
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

    def _results(self, units: list, scores: list[float], q: str) -> list[RetrievedChunk]:
        """Assemble results with context, citation and rank."""
        return materialise(
            units, scores, q, corpus=self.corpus, config=self.config, picker=self._picker
        )

    def dense_scores(self, query: str, *, limit: int) -> list[tuple[str, float]]:
        """The dense leg alone as ``(unit_id, cosine)``, best first.

        Exposed for the Dart parity fixture, which compares scores rather than
        ranks. Ranks are the wrong thing to assert across two implementations:
        cosines over one corpus cluster tightly enough that a 1e-7 float
        difference reorders near-ties, so an ordering test would fail on
        arithmetic that is correct. The score is the quantity being reproduced,
        and it is what the fusion consumes.

        Transliteration routing is honoured, so a romanised-Hindi query returns
        nothing here exactly as it contributes nothing to the fusion.

        Args:
            query: The user's query.
            limit: Maximum results to return.

        Returns:
            Ranked pairs, or an empty list when the dense leg does not run.
        """
        cfg = self.config
        if self._dense is None:
            return []
        routed_out = cfg.dense_weight * cfg.transliterated_dense_weight <= 0
        if routed_out and is_transliterated(query, self._vocabulary):
            return []
        return self._dense.search(query, limit=limit)

    def retrieve_ids(self, query: str, *, top_k: int | None = None) -> list[str]:
        """Ranked unit ids -- what the model's context is built from."""
        return [r.unit_id for r in self.retrieve(query, top_k=top_k)]

    def confidence(self, query: str) -> float:
        """Top embedding cosine for ``query``; 0.0 with no dense index.

        This is the signal the router declines on. It separates cleanly on
        this corpus where BM25 does not: in-corpus queries score 0.30-0.70,
        out-of-corpus ones 0.09-0.23.
        """
        if self._dense is None:
            return 0.0
        hits = self._dense.search(query, limit=1)
        return hits[0][1] if hits else 0.0

    def citations_for(
        self, hits: list[RetrievedChunk], query: str, *, limit: int = 5
    ) -> list[str]:
        """Rank the children covered by ``hits`` as a citation list."""
        return self._picker.rank([h.unit for h in hits], query, limit=limit)
