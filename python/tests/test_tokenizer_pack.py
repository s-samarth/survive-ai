"""The packed tokenizer must agree with Hugging Face on every real query.

A tokeniser bug is silent: a wrong subword split still produces a vector, just
one in the wrong place, so retrieval degrades with nothing to point at. These
tests are the only thing standing between that and the device.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from survive_rag.corpus.artifacts import FIXTURE_TEXTS
from survive_rag.retrieval.tokenizer_pack import pack_tokenizer
from survive_rag.retrieval.tokenizer_ref import encode, read_packed

ASSETS = Path(__file__).resolve().parents[2] / "assets" / "index"
GOLDSET = Path(__file__).resolve().parents[1] / "evals" / "goldsets" / "retrieval.jsonl"


def _queries() -> list[str]:
    """Every query in the retrieval golden set."""
    out = []
    for line in GOLDSET.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if stripped and not stripped.startswith("#"):
            out.append(json.loads(stripped)["query"])
    return out


@pytest.fixture(scope="module")
def packed():
    """The shipped packed tokenizer, as the app reads it."""
    path = ASSETS / "tokenizer.bin"
    if not path.is_file():
        pytest.skip("run `python -m survive_rag pack` to build the artifact")
    return read_packed(path)


@pytest.fixture(scope="module")
def reference():
    """Hugging Face's own tokenizer for the same model."""
    tokenizers = pytest.importorskip("tokenizers")
    from huggingface_hub import hf_hub_download

    return tokenizers.Tokenizer.from_file(
        hf_hub_download("google/embeddinggemma-300m", "tokenizer.json")
    )


def test_matches_huggingface_on_every_golden_query(packed, reference) -> None:
    """The full retrieval golden set, id for id."""
    mismatches = [
        query
        for query in _queries()
        if encode(query, packed) != reference.encode(query).ids
    ]
    assert not mismatches, f"{len(mismatches)} queries tokenise differently: {mismatches[:3]}"


@pytest.mark.parametrize("text", FIXTURE_TEXTS)
def test_matches_huggingface_on_edge_cases(text, packed, reference) -> None:
    """Devanagari, emoji, repeated whitespace and the empty string."""
    assert encode(text, packed) == reference.encode(text).ids


def test_task_prefixes_survive_packing(packed, reference) -> None:
    """The asymmetric prefixes are part of the input, not decoration.

    EmbeddingGemma is trained with them; tokenising them differently from the
    offline document side would shift every query in the space.
    """
    for prefix in ("task: search result | query: ", "title: none | text: "):
        assert encode(prefix + "flood", packed) == reference.encode(prefix + "flood").ids


def test_rejects_an_unsupported_tokenizer(tmp_path: Path) -> None:
    """A Unigram or non-byte-fallback model must fail loudly, not half-work."""
    bad = tmp_path / "tokenizer.json"
    bad.write_text(json.dumps({"model": {"type": "Unigram", "vocab": []}}), encoding="utf-8")
    with pytest.raises(ValueError, match="BPE"):
        pack_tokenizer(bad, tmp_path / "out.bin")


def test_fixture_is_current(packed) -> None:
    """The Dart fixture must match what the packer produces now.

    If this fails the fixture is stale, and the Dart parity test is checking
    the Dart tokeniser against an implementation that no longer ships.
    """
    fixture = Path(__file__).resolve().parents[2] / "test" / "fixtures" / "tokenizer_cases.json"
    if not fixture.is_file():
        pytest.skip("run `python -m survive_rag pack` to build the fixture")
    cases = json.loads(fixture.read_text(encoding="utf-8"))["cases"]
    for case in cases:
        assert encode(case["text"], packed) == case["ids"], case["text"]
