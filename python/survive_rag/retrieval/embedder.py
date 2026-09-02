"""Sentence embedding backends for the dense retrieval leg.

Two backends behind one protocol:

    * ``torch``  -- sentence-transformers, used in the lab. Convenient, and
      the reference the ONNX path is checked against.
    * ``onnx``   -- onnxruntime, the shape that actually ships. The app cannot
      carry PyTorch, so any model we adopt must survive this export.

Document vectors are computed **offline** and shipped inside the index
artifact, so a device only ever embeds the query: one forward pass over ~10
tokens, not a generation pass. That is why a dense leg is affordable here at
all despite a 6 GB memory budget.

Which models exist, and the prefixes they expect, live in
:mod:`survive_rag.retrieval.embedder_specs`; this module is only about running
one.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Protocol

import numpy as np

from .embedder_specs import MODELS, ONNX, TORCH, ModelSpec

__all__ = ["MODELS", "ONNX", "TORCH", "Embedder", "ModelSpec", "load_embedder"]


class Embedder(Protocol):
    """Encodes queries and documents into a shared vector space."""

    spec: ModelSpec

    @property
    def dim(self) -> int:
        """Width of the vectors this embedder returns."""
        ...

    def encode(self, texts: list[str], *, is_query: bool) -> np.ndarray:
        """Return L2-normalised vectors, one row per input text."""
        ...


def _l2(matrix: np.ndarray) -> np.ndarray:
    """L2-normalise rows so a dot product is a cosine similarity."""
    norms = np.linalg.norm(matrix, axis=1, keepdims=True)
    return matrix / np.maximum(norms, 1e-12)


@dataclass(slots=True)
class TorchEmbedder:
    """sentence-transformers backend -- the lab reference implementation."""

    spec: ModelSpec
    truncate_dim: int | None = None
    batch_size: int = 32
    _model: Any = None

    def __post_init__(self) -> None:
        from sentence_transformers import SentenceTransformer

        kwargs: dict[str, Any] = {"device": "cpu"}
        if self.truncate_dim and self.spec.matryoshka:
            kwargs["truncate_dim"] = self.truncate_dim
        self._model = SentenceTransformer(self.spec.repo_id, **kwargs)

    @property
    def dim(self) -> int:
        """Width after any Matryoshka truncation."""
        return self.truncate_dim or self.spec.dim

    def encode(self, texts: list[str], *, is_query: bool) -> np.ndarray:
        """Encode with the model's own asymmetric prefix applied."""
        prefix = self.spec.query_prefix if is_query else self.spec.doc_prefix
        prepared = [prefix + t for t in texts] if prefix else texts
        vectors = self._model.encode(
            prepared,
            batch_size=self.batch_size,
            convert_to_numpy=True,
            show_progress_bar=False,
            normalize_embeddings=False,
        )
        out = np.asarray(vectors, dtype=np.float32)
        if self.truncate_dim and not self.spec.matryoshka:
            out = out[:, : self.truncate_dim]
        return _l2(out)


def load_embedder(
    model: str, *, backend: str = TORCH, truncate_dim: int | None = None
) -> Embedder:
    """Build an embedder for a registered model key.

    Args:
        model: A key of :data:`MODELS`, e.g. ``"e5-small"``.
        backend: ``"torch"`` for the lab, ``"onnx"`` for shipping parity.
        truncate_dim: Matryoshka width; ignored by models without it.

    Returns:
        A ready :class:`Embedder`.

    Raises:
        KeyError: If ``model`` is not registered.
        ValueError: If ``backend`` is unknown.
    """
    spec = MODELS[model]
    if backend == TORCH:
        return TorchEmbedder(spec=spec, truncate_dim=truncate_dim)
    if backend == ONNX:
        from .embedder_onnx import OnnxEmbedder

        return OnnxEmbedder(spec=spec, truncate_dim=truncate_dim)
    raise ValueError(f"unknown embedding backend {backend!r}")
