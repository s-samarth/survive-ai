"""Load and chunk the whole guide corpus from disk."""

from __future__ import annotations

import json
from pathlib import Path

from .chunker import ChunkConfig, chunk_guide
from .models import Corpus
from .passages import PassageConfig, build_passages
from .topics import GUIDES_DIRNAME, TOPIC_KEYS


def repo_root(start: Path | None = None) -> Path:
    """Walk upward from ``start`` to the directory containing the guides.

    Args:
        start: Directory to search from; defaults to this file's location.

    Returns:
        The repository root.

    Raises:
        FileNotFoundError: If no ancestor contains ``docs/survival_guides``.
    """
    here = (start or Path(__file__).resolve()).resolve()
    for candidate in [here, *here.parents]:
        if (candidate / GUIDES_DIRNAME).is_dir():
            return candidate
    raise FileNotFoundError(f"{GUIDES_DIRNAME} not found above {here}")


def guides_dir(root: Path | None = None) -> Path:
    """Return the absolute path of the guides directory."""
    return (root or repo_root()) / GUIDES_DIRNAME


def load_corpus(
    root: Path | None = None,
    cfg: ChunkConfig | None = None,
    passages: PassageConfig | None = None,
) -> Corpus:
    """Chunk every guide in the corpus, at all three granularities.

    Args:
        root: Repository root; discovered automatically when omitted.
        cfg: Chunk sizing policy; defaults are used when omitted.
        passages: Retrieval-window sizing; defaults are used when omitted.

    Returns:
        A fully populated :class:`Corpus`.

    Raises:
        FileNotFoundError: If a topic listed in ``TOPIC_KEYS`` has no file.
    """
    directory = guides_dir(root)
    parents, children = [], []
    for key in TOPIC_KEYS:
        path = directory / f"{key}.md"
        if not path.is_file():
            raise FileNotFoundError(f"missing guide for topic {key!r}: {path}")
        guide_parents, guide_children = chunk_guide(
            path.read_text(encoding="utf-8"), key, cfg
        )
        parents.extend(guide_parents)
        children.extend(guide_children)
    pcfg = passages or PassageConfig()
    windows = build_passages(parents, children, pcfg) if pcfg.enabled else []
    return Corpus(children=children, parents=parents, passages=windows)


def _without_text(row: dict) -> dict:
    """Drop the joined body from a grouping row; its children carry it."""
    return {k: v for k, v in row.items() if k != "text"}


def export_index(corpus: Corpus, destination: Path) -> Path:
    """Write the chunked corpus as the artifact the Flutter app ships.

    Chunking happens once, here, at build time -- the app never parses
    markdown at runtime, so chunk ids (and therefore citations) are identical
    on every device and in every eval run.

    Only children carry text. Passages and parents are groupings of children
    and are stored as id lists, which the app joins on load: writing all three
    verbatim tripled the artifact for no information, and this ships in an
    APK where a megabyte is a real cost.

    Args:
        corpus: The chunked corpus.
        destination: Output ``.json`` path; parent directories are created.

    Returns:
        The path written.
    """
    destination.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "schema": 2,
        "children": [c.to_json() for c in corpus.children],
        "passages": [_without_text(p.to_json()) for p in corpus.passages],
        "parents": [_without_text(p.to_json()) for p in corpus.parents],
    }
    # No indent: this ships in an APK, and the file is machine-read.
    destination.write_text(
        json.dumps(payload, ensure_ascii=False, separators=(",", ":")),
        encoding="utf-8",
    )
    return destination
