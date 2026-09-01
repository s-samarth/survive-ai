"""Shared fixtures. The real corpus is chunked once per session."""

from __future__ import annotations

from pathlib import Path

import pytest

from survive_rag.corpus.loader import load_corpus, repo_root
from survive_rag.corpus.models import Corpus
from survive_rag.evals.goldset import GoldSet, load_goldset


@pytest.fixture(scope="session")
def root() -> Path:
    """Repository root."""
    return repo_root()


@pytest.fixture(scope="session")
def corpus(root: Path) -> Corpus:
    """The full corpus under the default chunking policy."""
    return load_corpus(root)


@pytest.fixture(scope="session")
def goldset(root: Path) -> GoldSet:
    """The hand-authored retrieval golden set."""
    return load_goldset(root / "python" / "goldset" / "retrieval.jsonl")
