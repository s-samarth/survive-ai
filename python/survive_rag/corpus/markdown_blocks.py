"""Split a markdown guide into flat, line-anchored semantic blocks.

This is deliberately a small hand-rolled scanner rather than a full markdown
parser: the corpus is authored to a known house style (``#`` title,
``## Part N`` sections, then paragraphs / bullet lists / numbered lists /
pipe tables), and we need exact source line numbers so the Flutter reader can
scroll to the cited paragraph.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

HEADING = "heading"
PARAGRAPH = "paragraph"
LIST = "list"
TABLE = "table"
RULE = "rule"

_HEADING_RE = re.compile(r"^(#{1,6})\s+(.*)$")
_LIST_ITEM_RE = re.compile(r"^\s{0,3}(?:[-*+]|\d{1,3}[.)])\s+")
_TABLE_ROW_RE = re.compile(r"^\s*\|")
_RULE_RE = re.compile(r"^\s*(?:-{3,}|\*{3,}|_{3,})\s*$")


@dataclass(frozen=True, slots=True)
class Block:
    """One contiguous markdown unit with its source line span.

    Attributes:
        kind: One of the module-level kind constants.
        text: Verbatim source text of the block, trailing whitespace stripped.
        line_start: 1-based inclusive first source line.
        line_end: 1-based inclusive last source line.
        level: Heading depth for ``kind == HEADING``, else 0.
    """

    kind: str
    text: str
    line_start: int
    line_end: int
    level: int = 0

    @property
    def is_heading(self) -> bool:
        """True when this block is a markdown heading."""
        return self.kind == HEADING


def _classify(line: str) -> str:
    """Return the block kind a line would start."""
    if _RULE_RE.match(line):
        return RULE
    if _HEADING_RE.match(line):
        return HEADING
    if _TABLE_ROW_RE.match(line):
        return TABLE
    if _LIST_ITEM_RE.match(line):
        return LIST
    return PARAGRAPH


def _continues(kind: str, line: str) -> bool:
    """True when ``line`` belongs to an in-progress block of ``kind``.

    A blank line always ends a block. Headings and rules are single-line.
    A list absorbs further list items and their indented continuations;
    a table absorbs further pipe rows; a paragraph absorbs plain text.
    """
    if not line.strip():
        return False
    next_kind = _classify(line)
    if kind in (HEADING, RULE):
        return False
    if next_kind in (HEADING, RULE):
        return False
    if kind == TABLE:
        return next_kind == TABLE
    if kind == LIST:
        return next_kind in (LIST, PARAGRAPH)
    return next_kind == PARAGRAPH


def parse_blocks(markdown: str) -> list[Block]:
    """Split markdown source into an ordered list of :class:`Block`.

    Blank lines and horizontal rules are consumed as separators and are not
    emitted. Line numbers are 1-based and refer to the original source, so a
    citation can address ``file.md:47``.

    Args:
        markdown: Full text of one guide file.

    Returns:
        Blocks in document order, excluding blanks and horizontal rules.
    """
    lines = markdown.splitlines()
    blocks: list[Block] = []
    i = 0
    total = len(lines)

    while i < total:
        line = lines[i]
        if not line.strip():
            i += 1
            continue

        kind = _classify(line)
        if kind == RULE:
            i += 1
            continue

        start = i
        i += 1
        while i < total and _continues(kind, lines[i]):
            i += 1

        raw = "\n".join(lines[start:i]).rstrip()
        level = 0
        text = raw
        if kind == HEADING:
            match = _HEADING_RE.match(raw)
            if match:
                level = len(match.group(1))
                text = match.group(2).strip()
        blocks.append(
            Block(kind=kind, text=text, line_start=start + 1, line_end=i, level=level)
        )

    return blocks


def strip_list_marker(text: str) -> str:
    """Remove a leading bullet or ordinal marker, for slug generation.

    ``"3. **Keep the bite below heart level.**"`` becomes
    ``"**Keep the bite below heart level.**"`` so the derived slug reads
    ``keep-the-bite-below-heart-level`` rather than ``3-keep-the-bite``.
    """
    return _LIST_ITEM_RE.sub("", text.lstrip(), count=1)
