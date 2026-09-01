"""Retrieval configuration -- every field is an eval knob.

A :class:`RetrievalConfig` is the unit the eval harness sweeps over: name one,
run it against the golden set, and compare rows in the report. Nothing in the
pipeline reads a tunable value from anywhere else.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass, replace
from typing import Any

from .corpus.chunker import ChunkConfig


@dataclass(frozen=True, slots=True)
class RetrievalConfig:
    """A named, fully-specified retrieval setup.

    Attributes:
        name: Identifier used as the row label in eval reports.
        chunking: Chunk sizing policy the corpus was built with.
        use_literal_leg: Score the raw query terms.
        use_expanded_leg: Score the synonym/Hinglish-expanded query.
        use_dense_leg: Reserved for the future embedding leg.
        max_expansions: Cap on added expansion terms.
        leg_limit: Candidates each leg contributes to fusion.
        rrf_k: RRF damping constant.
        literal_weight: RRF weight of the literal leg.
        expanded_weight: RRF weight of the expanded leg.
        dense_weight: RRF weight of the dense leg.
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
    chunking: ChunkConfig = ChunkConfig()
    use_literal_leg: bool = True
    use_expanded_leg: bool = True
    use_dense_leg: bool = False
    max_expansions: int = 10
    leg_limit: int = 50
    rrf_k: int = 60
    literal_weight: float = 1.0
    expanded_weight: float = 0.7
    dense_weight: float = 1.0
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
        return payload
