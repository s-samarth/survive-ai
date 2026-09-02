"""Embed the corpus once, offline, and ship the vectors with the app.

Documents do not change between launches, so there is no reason for a phone to
run 201 forward passes it could have been handed. Only the query has to be
embedded on the device, and that is a single pass over roughly ten tokens.
That asymmetry is the whole reason a dense leg fits inside the memory budget.

Vectors ship as raw ``float32`` in passage order, alongside a manifest naming
the model and dimension. Quantising them to ``int8`` would save 460 KB and
introduce a second, unmeasured source of drift on top of the quantised graph;
at this corpus size that is a bad trade.
"""

from __future__ import annotations

import json
import struct
from pathlib import Path

from ..retrieval.embedder import MODELS, load_embedder
from .models import Corpus

FORMAT_VERSION = 1


def embed_passages(corpus: Corpus, model: str, backend: str = "onnx") -> list[list[float]]:
    """Embed every passage with the document-side prefix.

    Args:
        corpus: The chunked corpus.
        model: Key into :data:`survive_rag.retrieval.embedder.MODELS`.
        backend: ``onnx`` by default -- the device runs the exported graph, so
            the shipped vectors must come from it too. Embedding documents with
            the float model and queries with the quantised one would put the
            two sides in subtly different spaces.

    Returns:
        One L2-normalised vector per passage, in corpus order.
    """
    embedder = load_embedder(model, backend=backend)
    texts = [p.text for p in corpus.passages]
    return [row.tolist() for row in embedder.encode(texts, is_query=False)]


def export_vectors(
    corpus: Corpus, destination: Path, *, model: str, backend: str = "onnx"
) -> tuple[Path, Path]:
    """Write passage vectors and their manifest.

    Two files are written: ``<destination>`` holding raw little-endian
    ``float32`` in passage order, and ``<destination>.json`` naming the model,
    dimension and passage ids. The ids are what let the app refuse a vector
    file that does not match the index it was built beside, instead of
    silently pairing text with someone else's embedding.

    Args:
        corpus: The chunked corpus.
        destination: Output ``.f32`` path; parent directories are created.
        model: Embedding model key.
        backend: Embedding backend.

    Returns:
        ``(vectors_path, manifest_path)``.
    """
    vectors = embed_passages(corpus, model, backend)
    dim = MODELS[model].dim
    destination.parent.mkdir(parents=True, exist_ok=True)
    with destination.open("wb") as out:
        for vector in vectors:
            out.write(struct.pack(f"<{len(vector)}f", *vector))

    manifest = destination.with_suffix(destination.suffix + ".json")
    manifest.write_text(
        json.dumps(
            {
                "version": FORMAT_VERSION,
                "model": model,
                "backend": backend,
                "dim": dim,
                "count": len(vectors),
                "query_prefix": MODELS[model].query_prefix,
                "ids": [p.chunk_id for p in corpus.passages],
            },
            ensure_ascii=False,
            separators=(",", ":"),
        ),
        encoding="utf-8",
    )
    return destination, manifest
