"""The dense retrieval leg: cosine similarity over cached unit embeddings.

Document vectors are computed once per (model, granularity, content) and
cached on disk, keyed by the chunk's ``content_sha``. Two consequences:

    * A sweep over fusion weights or rerank settings re-embeds nothing, so
      configurations stay comparable in seconds rather than minutes.
    * Editing one guide re-embeds only the chunks that actually changed,
      which is also exactly what the shipped index artifact needs.

The index is a plain normalised matrix and the search is one matmul. At this
corpus size (hundreds of units) that is microseconds and an ANN structure
would be pure overhead.
"""

from __future__ import annotations

import hashlib
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

from .embedder import Embedder

CACHE_DIRNAME = ".embed_cache"


def cache_dir(root: Path | None = None) -> Path:
    """Directory holding the embedding caches, created on demand."""
    base = root or Path(__file__).resolve().parents[2]
    path = base / CACHE_DIRNAME
    path.mkdir(parents=True, exist_ok=True)
    return path


def _cache_path(model_key: str, dim: int, root: Path | None = None) -> Path:
    """One cache file per model and vector width."""
    return cache_dir(root) / f"{model_key}-{dim}.npz"


def _load_cache(path: Path) -> dict[str, np.ndarray]:
    """Read a cache file into ``content_sha -> vector``, tolerating absence."""
    if not path.is_file():
        return {}
    with np.load(path, allow_pickle=False) as data:
        keys, vectors = data["keys"], data["vectors"]
    return {str(k): vectors[i] for i, k in enumerate(keys)}


def _save_cache(path: Path, table: dict[str, np.ndarray]) -> None:
    """Write ``content_sha -> vector`` atomically enough for a build step."""
    if not table:
        return
    keys = sorted(table)
    np.savez(
        path,
        keys=np.array(keys),
        vectors=np.stack([table[k] for k in keys]).astype(np.float32),
    )


def _sha(text: str) -> str:
    """Content key for a unit that carries no ``content_sha`` of its own."""
    return hashlib.sha256(text.encode("utf-8")).hexdigest()[:16]


@dataclass(slots=True)
class DenseIndex:
    """A searchable matrix of unit vectors, plus the embedder for queries."""

    embedder: Embedder
    ids: list[str] = field(default_factory=list)
    matrix: np.ndarray = field(default_factory=lambda: np.zeros((0, 0), np.float32))

    def search(self, query: str, limit: int = 50) -> list[tuple[str, float]]:
        """Return ``(unit_id, cosine)`` for the closest units, best first.

        Args:
            query: Raw user query; the model's query prefix is applied inside.
            limit: Maximum results to return.

        Returns:
            Ranked ``(id, score)`` pairs, at most ``limit`` of them.
        """
        if not self.ids:
            return []
        vector = self.embedder.encode([query], is_query=True)[0]
        scores = self.matrix @ vector
        top = np.argsort(-scores)[:limit]
        return [(self.ids[i], float(scores[i])) for i in top]


def build_dense_index(
    units: list, embedder: Embedder, *, root: Path | None = None, use_cache: bool = True
) -> DenseIndex:
    """Embed every unit, reusing cached vectors for unchanged content.

    Args:
        units: Chunks to index; each needs ``chunk_id`` and ``text``.
        embedder: The model to encode with.
        root: Repository root, for locating the cache.
        use_cache: Set False to force a full re-embed.

    Returns:
        A populated :class:`DenseIndex`.
    """
    spec_key = embedder.spec.key
    path = _cache_path(spec_key, embedder.dim, root)
    table = _load_cache(path) if use_cache else {}

    keys = [getattr(u, "content_sha", "") or _sha(u.text) for u in units]
    missing = [i for i, k in enumerate(keys) if k not in table]
    if missing:
        fresh = embedder.encode([units[i].text for i in missing], is_query=False)
        for slot, i in enumerate(missing):
            table[keys[i]] = fresh[slot]
        if use_cache:
            _save_cache(path, table)

    return DenseIndex(
        embedder=embedder,
        ids=[u.chunk_id for u in units],
        matrix=np.stack([table[k] for k in keys]).astype(np.float32),
    )
