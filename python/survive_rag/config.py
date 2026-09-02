"""Retrieval configuration -- every field is an eval knob.

A :class:`RetrievalConfig` is the unit the eval harness sweeps over: name one,
run it against the golden set, and compare rows in the report. Nothing in the
pipeline reads a tunable value from anywhere else.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass, field, replace
from typing import Any

from .corpus.chunker import ChunkConfig
from .corpus.models import PASSAGE
from .corpus.passages import PassageConfig


@dataclass(frozen=True, slots=True)
class RetrievalConfig:
    """A named, fully-specified retrieval setup.

    Attributes:
        name: Identifier used as the row label in eval reports.
        chunking: Chunk sizing policy the corpus was built with.
        passages: Retrieval-window sizing for the ``passage`` granularity.
        granularity: Which view retrieval scores -- ``child`` (citation-sized),
            ``passage`` (overlapping windows), or ``parent`` (whole sections).
            Results are always mapped back to a child for the citation.
        use_literal_leg: Score the raw query terms.
        use_expanded_leg: Score the synonym/Hinglish-expanded query.
        use_dense_leg: Score cosine similarity against unit embeddings.
        embed_model: Key into :data:`survive_rag.retrieval.embedder.MODELS`.
        embed_backend: ``torch`` in the lab, ``onnx`` for shipping parity.
        embed_dim: Matryoshka truncation width; None keeps the native width.
        max_expansions: Cap on added expansion terms.
        leg_limit: Candidates each leg contributes to fusion.
        rrf_k: RRF damping constant.
        literal_weight: RRF weight of the literal leg.
        expanded_weight: RRF weight of the expanded leg.
        dense_weight: RRF weight of the dense leg.
        transliterated_dense_weight: Multiplier applied to ``dense_weight``
            when the query uses romanised-Hindi bridge vocabulary. Embedding
            models are trained on Devanagari Hindi, not Latin-script
            transliteration, so the dense leg measurably *hurts* those
            queries; 0.0 routes them to the lexical legs alone.
        heading_boost: Times heading text is repeated when indexing.
        index_parent_terms: Also index each child under its parent's vocabulary.
            Small children match fewer queries simply because they contain
            fewer words; this recovers the recall of coarse chunking without
            giving up the citation precision of small children.
        rerank: Apply the heuristic reranker to fused candidates.
        rerank_depth: How many fused candidates the reranker considers.
        mmr_lambda: Relevance/diversity trade-off; 1.0 disables diversification.
        top_k: Children returned to the caller.
        expand_to_parents: Return enclosing sections rather than bare children.
        max_parent_tokens: Budget for expanded parents; overflow falls back to
            the child text so a single huge section cannot blow the prompt.
    """

    name: str = "baseline"
    chunking: ChunkConfig = field(default_factory=ChunkConfig)
    passages: PassageConfig = field(default_factory=PassageConfig)
    granularity: str = PASSAGE
    use_literal_leg: bool = True
    use_expanded_leg: bool = True
    use_dense_leg: bool = False
    embed_model: str = "embeddinggemma"
    embed_backend: str = "torch"
    embed_dim: int | None = None
    max_expansions: int = 10
    leg_limit: int = 50
    rrf_k: int = 60
    literal_weight: float = 1.0
    expanded_weight: float = 0.7
    dense_weight: float = 1.5
    transliterated_dense_weight: float = 0.0
    heading_boost: int = 2
    index_parent_terms: bool = False
    rerank: bool = True
    rerank_depth: int = 25
    mmr_lambda: float = 0.75
    top_k: int = 5
    expand_to_parents: bool = True
    max_parent_tokens: int = 450

    def with_(self, **overrides: Any) -> RetrievalConfig:
        """Return a copy with ``overrides`` applied; used to build sweeps."""
        return replace(self, **overrides)

    def to_json(self) -> dict[str, Any]:
        """Serialise for inclusion in the eval report."""
        payload = asdict(self)
        payload["chunking"] = asdict(self.chunking)
        payload["passages"] = asdict(self.passages)
        return payload

    @property
    def corpus_key(self) -> tuple[Any, ...]:
        """Identity of the corpus this config needs, for build caching."""
        return (self.chunking, self.passages)


# The measured best configuration, and what the app should ship. Kept separate
# from the defaults only because ``use_dense_leg`` pulls in numpy and an
# embedding model, which the zero-dependency lexical path does not need.
#
# Retrieval eval, 346 cases: Recall@5 0.897, Recall@20 0.979, MRR 0.767,
# citation Recall@5 0.849.
#
# EmbeddingGemma-300m is gated on Hugging Face, which is why the dense leg is
# off in the plain defaults: the lexical path must keep working for anyone who
# has not accepted the licence, and for the CI job that installs nothing.
RECOMMENDED = RetrievalConfig(name="recommended", use_dense_leg=True)
