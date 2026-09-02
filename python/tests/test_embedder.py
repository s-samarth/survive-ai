"""Embedding backends: registry hygiene, and torch/ONNX parity.

The parity tests need the Hugging Face Hub, so they are opt-in via
``SURVIVE_RAG_NETWORK_TESTS=1``. They matter because the lab measures models
through PyTorch while the app would run them through ONNX: if the two
disagree, every number in the bake-off is about a model we cannot ship.
"""

from __future__ import annotations

import os

import pytest

from survive_rag.retrieval.embedder import MODELS, ModelSpec

NETWORK = os.environ.get("SURVIVE_RAG_NETWORK_TESTS") == "1"
needs_network = pytest.mark.skipif(not NETWORK, reason="set SURVIVE_RAG_NETWORK_TESTS=1")


def test_every_registered_model_declares_its_pooling() -> None:
    """Wrong pooling silently produces plausible but much worse vectors."""
    assert all(spec.pooling in ("mean", "cls") for spec in MODELS.values())


def test_asymmetric_models_declare_both_prefixes() -> None:
    """E5 is trained with query:/passage: markers and degrades without them."""
    for spec in MODELS.values():
        if spec.repo_id.startswith("intfloat/"):
            assert spec.query_prefix and spec.doc_prefix


def test_registry_keys_match_their_specs() -> None:
    """A mismatched key would mislabel every row of the bake-off report."""
    assert all(key == spec.key for key, spec in MODELS.items())


def test_spec_is_hashable_for_caching() -> None:
    """Embedding caches are keyed by model; the spec must be usable as a key."""
    assert len({MODELS["e5-base"], MODELS["e5-base"]}) == 1
    assert isinstance(MODELS["e5-base"], ModelSpec)


@needs_network
@pytest.mark.parametrize("key", ["minilm", "bge-small", "e5-small", "e5-base"])
def test_onnx_matches_torch(key: str) -> None:
    """The shipped backend must reproduce the measured backend exactly."""
    from survive_rag.retrieval.embedder import load_embedder

    texts = ["DO NOT apply a tourniquet.", "wash the wound with soap and water"]
    torch_vectors = load_embedder(key).encode(texts, is_query=False)
    onnx_vectors = load_embedder(key, backend="onnx").encode(texts, is_query=False)
    for a, b in zip(torch_vectors, onnx_vectors, strict=True):
        assert float(a @ b) > 0.999


@needs_network
def test_query_and_document_prefixes_differ_for_e5() -> None:
    """Encoding the same text as query and as passage must not collide."""
    from survive_rag.retrieval.embedder import load_embedder

    embedder = load_embedder("e5-small")
    as_query = embedder.encode(["snake bite"], is_query=True)[0]
    as_doc = embedder.encode(["snake bite"], is_query=False)[0]
    assert float(as_query @ as_doc) < 0.9999
