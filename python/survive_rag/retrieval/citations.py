"""Choosing which child a result cites.

Retrieval scores passages, because a 30-token prohibition holds too few terms
to match on its own. But a citation has to land on a paragraph -- the user is
scrolled to it and must recognise the answer. So every retrieved unit is
mapped back to a child, and picking *which* child is its own problem:

Lexical overlap cannot do it. Every child of a relevant section shares the
query's terms, so term counting picks nearly at random within the right
section -- measurably, it costs 12 points of citation recall against scoring
the children densely. Ranking children by embedding similarity to the query,
across all retrieved passages at once, recovers most of that.

The child vectors are the same ones the shipped index artifact already
carries, so this costs one dot product per candidate at query time.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

from ..corpus.models import Corpus
from .tokenizer import index_terms


def children_of(unit: Any) -> list[str]:
    """Child ids a retrieved unit covers; a child covers only itself."""
    return list(getattr(unit, "child_ids", ()) or (unit.chunk_id,))


@dataclass(slots=True)
class CitationPicker:
    """Maps retrieved units back to the children a citation should link to.

    Attributes:
        corpus: The chunked corpus, for child lookup.
        embedder: Query encoder, or None to fall back to lexical overlap.
        vectors: ``child_id -> vector``, empty when running lexically.
    """

    corpus: Corpus
    embedder: Any = None
    vectors: dict[str, Any] = field(default_factory=dict)

    @property
    def is_dense(self) -> bool:
        """True when children can be scored semantically."""
        return self.embedder is not None and bool(self.vectors)

    def _encode(self, query: str) -> Any:
        """Encode the query once per call rather than once per candidate."""
        return self.embedder.encode([query], is_query=True)[0]

    def _lexical(self, kids: list[str], query: str, fallback: str) -> str:
        """Pick the child sharing the most query terms."""
        terms = set(index_terms(query))
        children = [c for c in (self.corpus.child(k) for k in kids) if c is not None]
        if not children:
            return fallback
        return max(children, key=lambda c: len(terms & set(index_terms(c.text)))).chunk_id

    def for_unit(self, unit: Any, query: str) -> str:
        """The single child that best answers ``query`` inside ``unit``."""
        kids = children_of(unit)
        if self.is_dense:
            known = [c for c in kids if c in self.vectors]
            if known:
                vector = self._encode(query)
                return max(known, key=lambda c: float(self.vectors[c] @ vector))
        return self._lexical(kids, query, unit.chunk_id)

    def rank(self, units: list[Any], query: str, *, limit: int = 5) -> list[str]:
        """Rank every child covered by ``units`` as a citation list.

        Flattening the retrieved passages back to their children and ranking
        those together beats picking one child per passage, because the two
        best citations are often inside the same section.

        Args:
            units: Retrieved units, best first.
            query: The original query.
            limit: Maximum citations to return.

        Returns:
            Child ids, best first.
        """
        kids: list[str] = []
        seen: set[str] = set()
        for unit in units:
            for child_id in children_of(unit):
                if child_id not in seen:
                    seen.add(child_id)
                    kids.append(child_id)

        if not self.is_dense:
            return [self.for_unit(u, query) for u in units][:limit]

        vector = self._encode(query)
        known = [c for c in kids if c in self.vectors]
        known.sort(key=lambda c: -float(self.vectors[c] @ vector))
        return known[:limit]


def build_picker(corpus: Corpus, config: Any) -> CitationPicker:
    """Build a picker, dense when the config enables embeddings.

    Args:
        corpus: The chunked corpus.
        config: A :class:`~survive_rag.config.RetrievalConfig`.

    Returns:
        A ready :class:`CitationPicker`.
    """
    if not config.use_dense_leg:
        return CitationPicker(corpus=corpus)

    from .dense import build_dense_index
    from .embedder import load_embedder

    embedder = load_embedder(
        config.embed_model,
        backend=config.embed_backend,
        truncate_dim=config.embed_dim,
    )
    index = build_dense_index(corpus.children, embedder)
    return CitationPicker(
        corpus=corpus,
        embedder=embedder,
        vectors={cid: index.matrix[i] for i, cid in enumerate(index.ids)},
    )
