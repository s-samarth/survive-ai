"""Okapi BM25 over the child chunks -- pure Python, no dependencies.

Implemented here rather than imported so the exact scoring is auditable and
reproducible against SQLite FTS5's ``bm25()`` on the Dart side. Field weighting
mirrors the app: heading text counts more than body text, because a heading
match is strong evidence of topical fit in a corpus this structured.
"""

from __future__ import annotations

import math
from collections import Counter
from dataclasses import dataclass, field

K1 = 1.2
B = 0.75


@dataclass(slots=True)
class BM25Index:
    """An inverted index with BM25 scoring over a fixed document set.

    Attributes:
        doc_ids: Document identifiers in insertion order.
        doc_len: Token length of each document, parallel to ``doc_ids``.
        postings: Term -> list of ``(doc position, term frequency)``.
        avg_len: Mean document length, used for length normalisation.
        k1: Term-frequency saturation parameter.
        b: Length-normalisation strength.
    """

    doc_ids: list[str] = field(default_factory=list)
    doc_len: list[int] = field(default_factory=list)
    postings: dict[str, list[tuple[int, int]]] = field(default_factory=dict)
    avg_len: float = 0.0
    k1: float = K1
    b: float = B

    @property
    def n_docs(self) -> int:
        """Number of indexed documents."""
        return len(self.doc_ids)

    def _idf(self, term: str) -> float:
        """Robertson-Sparck-Jones IDF in its smoothed ``log(1 + x)`` form.

        The ``1 +`` keeps the value positive for a term that appears in every
        document, where the unsmoothed form goes negative and would actively
        penalise a match. Such a term still scores near zero, so it cannot
        discriminate -- which is the behaviour we want, not an exclusion.
        """
        df = len(self.postings.get(term, ()))
        if df == 0:
            return 0.0
        return math.log(1.0 + (self.n_docs - df + 0.5) / (df + 0.5))

    def score(self, query_terms: list[str]) -> dict[str, float]:
        """Score every document that contains at least one query term.

        Args:
            query_terms: Already-tokenised (and optionally expanded) terms.

        Returns:
            Mapping of document id to BM25 score, unsorted and sparse.
        """
        scores: dict[int, float] = {}
        for term, q_tf in Counter(query_terms).items():
            posting = self.postings.get(term)
            if not posting:
                continue
            idf = self._idf(term)
            if idf <= 0.0:
                continue
            weight = idf * q_tf
            for pos, tf in posting:
                norm = 1.0 - self.b + self.b * (self.doc_len[pos] / self.avg_len)
                scores[pos] = scores.get(pos, 0.0) + weight * (
                    tf * (self.k1 + 1.0) / (tf + self.k1 * norm)
                )
        return {self.doc_ids[pos]: s for pos, s in scores.items()}

    def search(self, query_terms: list[str], limit: int = 50) -> list[tuple[str, float]]:
        """Return the top ``limit`` ``(doc_id, score)`` pairs, best first."""
        ranked = sorted(
            self.score(query_terms).items(), key=lambda kv: (-kv[1], kv[0])
        )
        return ranked[:limit]


def build_index(
    documents: list[tuple[str, list[str]]], *, k1: float = K1, b: float = B
) -> BM25Index:
    """Build a :class:`BM25Index` from ``(doc_id, terms)`` pairs.

    Args:
        documents: Documents as already-tokenised term lists.
        k1: Term-frequency saturation parameter.
        b: Length-normalisation strength.

    Returns:
        A populated, ready-to-search index.
    """
    index = BM25Index(k1=k1, b=b)
    for doc_id, terms in documents:
        pos = len(index.doc_ids)
        index.doc_ids.append(doc_id)
        index.doc_len.append(max(1, len(terms)))
        for term, tf in Counter(terms).items():
            index.postings.setdefault(term, []).append((pos, tf))
    index.avg_len = (
        sum(index.doc_len) / len(index.doc_len) if index.doc_len else 1.0
    )
    return index
