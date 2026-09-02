"""Parent/child chunking of a markdown guide.

Retrieval scores *children* (small, sharp, one instruction each) but the model
reads *parents* (a whole ``## Part N`` section, so no step is missing its
context). This is the standard parent-document pattern, with one addition: the
child is also the citation target, so children are packed to a size a reader
can be scrolled to and recognise -- roughly one screenful, never a fragment.

Sizing policy (tokens, estimated):
    * ``min_tokens``    -- keep absorbing units below this
    * ``target_tokens`` -- flush once reached
    * ``max_tokens``    -- never exceed by adding a further unit

Semantic flushes override size: a paragraph following list items starts a new
child, which is what keeps "Common Krait" separate from "Spectacled Cobra".
"""

from __future__ import annotations

from dataclasses import dataclass

from .markdown_blocks import (
    LIST,
    PARAGRAPH,
    TABLE,
    Block,
    parse_blocks,
    strip_list_marker,
)
from .models import ChildChunk, ParentChunk
from .packing import estimate_tokens, is_prohibition, naming_block, pack
from .slugify import child_id, content_sha, make_unique, parent_id, slugify

_OVERVIEW_TITLE = "Overview"


@dataclass(frozen=True, slots=True)
class ChunkConfig:
    """Tunable sizing policy for the packer; every field is an eval knob."""

    min_tokens: int = 30
    target_tokens: int = 140
    max_tokens: int = 220
    explode_lists: bool = True
    anchor_flush: bool = True


def _child_from_group(
    group: list[Block],
    *,
    topic: str,
    heading_slug: str,
    heading_path: str,
    ordinal: int,
    taken: set[str],
) -> ChildChunk:
    """Materialise one :class:`ChildChunk` from a packed group of units."""
    text = "\n".join(b.text for b in group).strip()
    slug = make_unique(slugify(strip_list_marker(naming_block(group).text)), taken)
    kinds = {b.kind for b in group}
    kind = TABLE if TABLE in kinds else (LIST if LIST in kinds else PARAGRAPH)
    return ChildChunk(
        chunk_id=child_id(topic, heading_slug, slug),
        parent_id=parent_id(topic, heading_slug),
        topic=topic,
        heading_path=heading_path,
        text=text,
        block_kind=kind,
        ordinal=ordinal,
        line_start=group[0].line_start,
        line_end=group[-1].line_end,
        content_sha=content_sha(text),
        token_estimate=estimate_tokens(text),
        is_prohibition=is_prohibition(text),
    )


def chunk_guide(
    markdown: str, topic: str, cfg: ChunkConfig | None = None
) -> tuple[list[ParentChunk], list[ChildChunk]]:
    """Chunk one guide into parents and children.

    Args:
        markdown: Full source of the guide file.
        topic: Guide key, e.g. ``"bites"``; the first id segment.
        cfg: Sizing policy; defaults to :class:`ChunkConfig`.

    Returns:
        ``(parents, children)`` in document order.
    """
    cfg = cfg or ChunkConfig()
    blocks = parse_blocks(markdown)
    doc_title = next((b.text for b in blocks if b.is_heading and b.level == 1), topic)

    sections = _split_sections(blocks)
    parents: list[ParentChunk] = []
    children: list[ChildChunk] = []

    for title, body in sections:
        if not body:
            continue
        heading_slug = slugify(title)
        heading_path = f"{doc_title} > {title}" if title != _OVERVIEW_TITLE else doc_title
        pid = parent_id(topic, heading_slug)
        taken: set[str] = set()
        groups = pack(body, cfg)
        section_children = [
            _child_from_group(
                g,
                topic=topic,
                heading_slug=heading_slug,
                heading_path=heading_path,
                ordinal=i,
                taken=taken,
            )
            for i, g in enumerate(groups)
        ]
        parent_text = "\n\n".join(b.text for b in body).strip()
        parents.append(
            ParentChunk(
                parent_id=pid,
                topic=topic,
                title=title,
                heading_path=heading_path,
                text=parent_text,
                line_start=body[0].line_start,
                line_end=body[-1].line_end,
                token_estimate=estimate_tokens(parent_text),
                child_ids=tuple(c.chunk_id for c in section_children),
            )
        )
        children.extend(section_children)

    return parents, children


def _split_sections(blocks: list[Block]) -> list[tuple[str, list[Block]]]:
    """Group blocks under their nearest ``##`` heading.

    Content appearing before the first ``##`` becomes an ``Overview`` section
    so that a guide's framing paragraphs remain retrievable.
    """
    sections: list[tuple[str, list[Block]]] = []
    title = _OVERVIEW_TITLE
    body: list[Block] = []
    for block in blocks:
        if block.is_heading and block.level == 1:
            continue
        if block.is_heading and block.level == 2:
            sections.append((title, body))
            title, body = block.text, []
            continue
        body.append(block)
    sections.append((title, body))
    return [(t, b) for t, b in sections if b]
