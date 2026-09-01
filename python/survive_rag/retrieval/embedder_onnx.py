"""onnxruntime embedding backend -- the shape that actually ships.

The app cannot carry PyTorch, so any embedding model we adopt has to survive
an ONNX export and produce the same vectors through it. This backend exists to
prove that before a model is chosen, not after: ``tests/test_embedder.py``
asserts the two backends agree to within a cosine of 1e-3.

Only the graph, the tokenizer and onnxruntime are needed at inference, which
is the same set the Flutter side would carry.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

import numpy as np

from .embedder import ModelSpec, _l2

MAX_SEQUENCE = 512


def _download(spec: ModelSpec) -> tuple[str, str]:
    """Fetch the ONNX graph and tokenizer for ``spec`` from the Hub.

    Returns:
        ``(onnx_path, tokenizer_path)`` as local filesystem paths.

    Raises:
        FileNotFoundError: If the repository ships no ONNX export.
    """
    from huggingface_hub import hf_hub_download

    tried: list[str] = []
    graph = ""
    for candidate in (spec.onnx_file, "model.onnx", "onnx/model_quantized.onnx"):
        try:
            graph = hf_hub_download(spec.repo_id, candidate)
            break
        except Exception as exc:  # noqa: BLE001 - a miss just means try the next name
            tried.append(f"{candidate}: {type(exc).__name__}")
    if not graph:
        raise FileNotFoundError(
            f"{spec.repo_id} ships no ONNX export (tried {'; '.join(tried)})"
        )
    return graph, hf_hub_download(spec.repo_id, "tokenizer.json")


def _pool(hidden: np.ndarray, mask: np.ndarray, how: str) -> np.ndarray:
    """Reduce token vectors to one sentence vector per row."""
    if how == "cls":
        return hidden[:, 0]
    weights = mask[..., None].astype(np.float32)
    return (hidden * weights).sum(axis=1) / np.maximum(weights.sum(axis=1), 1e-9)


@dataclass(slots=True)
class OnnxEmbedder:
    """Runs a exported sentence encoder under onnxruntime."""

    spec: ModelSpec
    truncate_dim: int | None = None
    batch_size: int = 32
    _session: Any = None
    _tokenizer: Any = None

    def __post_init__(self) -> None:
        import onnxruntime as ort
        from tokenizers import Tokenizer

        graph, tokenizer_path = _download(self.spec)
        self._tokenizer = Tokenizer.from_file(tokenizer_path)
        self._tokenizer.enable_truncation(MAX_SEQUENCE)
        self._tokenizer.enable_padding()
        self._session = ort.InferenceSession(
            graph, providers=["CPUExecutionProvider"]
        )

    @property
    def dim(self) -> int:
        """Width after any Matryoshka truncation."""
        return self.truncate_dim or self.spec.dim

    def _feed(self, encodings: list) -> dict[str, np.ndarray]:
        """Build the input dict, supplying only the inputs the graph declares."""
        ids = np.array([e.ids for e in encodings], dtype=np.int64)
        mask = np.array([e.attention_mask for e in encodings], dtype=np.int64)
        available = {i.name for i in self._session.get_inputs()}
        feed = {"input_ids": ids, "attention_mask": mask}
        if "token_type_ids" in available:
            feed["token_type_ids"] = np.zeros_like(ids)
        return {k: v for k, v in feed.items() if k in available}

    def encode(self, texts: list[str], *, is_query: bool) -> np.ndarray:
        """Return L2-normalised vectors, one row per input text."""
        prefix = self.spec.query_prefix if is_query else self.spec.doc_prefix
        prepared = [prefix + t for t in texts] if prefix else list(texts)

        chunks: list[np.ndarray] = []
        for start in range(0, len(prepared), self.batch_size):
            batch = prepared[start : start + self.batch_size]
            encodings = self._tokenizer.encode_batch(batch)
            outputs = self._session.run(None, self._feed(encodings))
            mask = np.array([e.attention_mask for e in encodings], dtype=np.int64)
            chunks.append(_pool(outputs[0], mask, self.spec.pooling))

        out = np.concatenate(chunks).astype(np.float32)
        if self.truncate_dim:
            out = out[:, : self.truncate_dim]
        return _l2(out)
