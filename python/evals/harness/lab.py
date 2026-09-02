"""Shared setup for every harness: build the corpus and retriever once.

Each eval needs the same two objects from a :class:`RetrievalConfig`, and
building them is expensive enough (chunking, BM25 indexing, and for the dense
legs a model load plus an embedding pass) that repeating it per command would
dominate the runtime of the cheap analyses.
"""

from __future__ import annotations

from functools import lru_cache
from pathlib import Path

from survive_rag.config import RetrievalConfig
from survive_rag.corpus.loader import load_corpus, repo_root
from survive_rag.corpus.models import Corpus
from survive_rag.retrieval.pipeline import Retriever

GOLDSET_DIRNAME = "goldsets"


def goldset_dir() -> Path:
    """Directory holding the golden sets, next to this package."""
    return Path(__file__).resolve().parents[1] / GOLDSET_DIRNAME


def goldset_path(name: str) -> Path:
    """Path of one golden set by bare name, e.g. ``"retrieval"``."""
    return goldset_dir() / f"{name}.jsonl"


@lru_cache(maxsize=8)
def corpus_for(config: RetrievalConfig) -> Corpus:
    """Chunk the corpus the way ``config`` asks for, memoised across commands."""
    return load_corpus(repo_root(), cfg=config.chunking, passages=config.passages)


def retriever_for(config: RetrievalConfig) -> Retriever:
    """Build a retriever for ``config``, reusing an already-chunked corpus."""
    return Retriever(corpus=corpus_for(config), config=config)


def reference_corpus() -> Corpus:
    """The corpus golden-set labels were authored against.

    Labels resolve to source line spans through this corpus, which is what
    lets one set score any chunking policy or granularity.
    """
    return load_corpus(repo_root())
