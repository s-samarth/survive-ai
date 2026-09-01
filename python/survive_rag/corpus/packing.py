"""Grouping markdown units into child-sized chunks.

The sizing policy in :class:`~.chunker.ChunkConfig` is only half the story.
Two semantic rules override it, and both exist because of what this corpus is:

* **Anchors** -- a bold sub-topic label, or a ``DO NOT`` line -- always start a
  new chunk. The prohibitions are the highest-stakes text in the corpus and
  each one must be independently retrievable and independently citable.
* **Bare labels** -- ``"**Immediately:**"`` -- are never separated from the
  list they introduce, because alone they say nothing.
"""

from __future__ import annotations

import re
from typing import TYPE_CHECKING

from .markdown_blocks import LIST, PARAGRAPH, TABLE, Block, strip_list_marker

if TYPE_CHECKING:
    from .chunker import ChunkConfig

_LIST_ITEM_SPLIT = re.compile(r"^(?=\s{0,3}(?:[-*+]|\d{1,3}[.)])\s)", re.MULTILINE)
_PROHIBITION_RE = re.compile(
    r"\b(do not|don'?t|never|must not|avoid|no tourniquet)\b", re.IGNORECASE
)
_BOLD_RUN_RE = re.compile(r"\*\*(.+?)\*\*", re.DOTALL)


def estimate_tokens(text: str) -> int:
    """Estimate token count from character length (~4 chars/token)."""
    return max(1, round(len(text) / 4))


def is_prohibition(text: str) -> bool:
    """True when the block tells the reader not to do something."""
    return bool(_PROHIBITION_RE.search(text))


def is_anchor(block: Block) -> bool:
    """True when a unit is a semantic anchor that should start its own child.

    Two shapes qualify, both chosen because they are the things a citation
    most often needs to point at exactly:

    * a **bold label line** -- ``"**2. Common Krait (Bungarus caeruleus)**"``
      introduces a new sub-topic, so it must not be glued to the tail of the
      previous one;
    * a **prohibition** -- ``"**DO NOT apply a tourniquet.** ..."``. These are
      the highest-stakes lines in the corpus and each one deserves to be
      independently retrievable and independently linkable.
    """
    first_line = block.text.strip().splitlines()[0] if block.text.strip() else ""
    if not first_line:
        return False
    if block.kind == PARAGRAPH:
        bold = sum(len(m.group(1)) for m in _BOLD_RUN_RE.finditer(first_line))
        stripped = strip_list_marker(first_line)
        if bold and bold >= 0.6 * len(stripped):
            return True
    return bool(_PROHIBITION_RE.match(strip_list_marker(first_line).lstrip("*")))


def is_bare_label(block: Block) -> bool:
    """True for a short colon-terminated lead-in such as ``"**Immediately:**"``.

    These introduce the list beneath them and are meaningless alone, so the
    packer must never flush between a bare label and its content.
    """
    text = block.text.strip()
    if "\n" in text or estimate_tokens(text) > 20:
        return False
    return text.rstrip("*").rstrip().endswith(":")


def _explode(block: Block) -> list[Block]:
    """Split a list block into one block per item, preserving line numbers."""
    if block.kind != LIST:
        return [block]
    pieces = [p for p in _LIST_ITEM_SPLIT.split(block.text) if p.strip()]
    if len(pieces) <= 1:
        return [block]
    out: list[Block] = []
    line = block.line_start
    for piece in pieces:
        span = piece.rstrip("\n").count("\n") + 1
        out.append(
            Block(kind=LIST, text=piece.rstrip(), line_start=line, line_end=line + span - 1)
        )
        line += piece.count("\n") if piece.endswith("\n") else span
    return out


def _units(blocks: list[Block], cfg: ChunkConfig) -> list[Block]:
    """Expand body blocks into the atomic units the packer will pack."""
    if not cfg.explode_lists:
        return blocks
    out: list[Block] = []
    for block in blocks:
        out.extend(_explode(block))
    return out


def _should_flush(buffer: list[Block], unit: Block, cfg: ChunkConfig) -> bool:
    """Decide whether ``buffer`` should be emitted before absorbing ``unit``."""
    if not buffer:
        return False
    size = sum(estimate_tokens(b.text) for b in buffer)
    has_list = any(b.kind == LIST for b in buffer)
    # A bare label must keep whatever follows it; never flush it away alone.
    if len(buffer) == 1 and is_bare_label(buffer[0]):
        return False
    # Anchors start a new child regardless of how small the buffer is.
    if cfg.anchor_flush and is_anchor(unit):
        return True
    # Semantic boundary: prose after bullets introduces a new sub-topic.
    if unit.kind == PARAGRAPH and has_list and size >= cfg.min_tokens:
        return True
    # Tables are self-contained on both sides.
    if unit.kind == TABLE or any(b.kind == TABLE for b in buffer):
        return True
    if size >= cfg.target_tokens:
        return True
    return size + estimate_tokens(unit.text) > cfg.max_tokens and size >= cfg.min_tokens


def _pack(units: list[Block], cfg: ChunkConfig) -> list[list[Block]]:
    """Group units into child-sized buffers according to the sizing policy."""
    groups: list[list[Block]] = []
    buffer: list[Block] = []
    for unit in units:
        if _should_flush(buffer, unit, cfg):
            groups.append(buffer)
            buffer = []
        buffer.append(unit)
    if buffer:
        groups.append(buffer)
    return _merge_undersized(groups, cfg)


def _merge_undersized(groups: list[list[Block]], cfg: ChunkConfig) -> list[list[Block]]:
    """Fold runt groups into a neighbour so no child is a context-free fragment.

    Prohibitions are exempt: a standalone ``"DO NOT ..."`` child is short by
    design and is the most valuable citation target in the corpus.
    """
    if len(groups) < 2:
        return groups
    merged: list[list[Block]] = []
    pending: list[Block] = []
    for group in groups:
        group = pending + group
        pending = []
        size = sum(estimate_tokens(b.text) for b in group)
        exempt = any(is_anchor(b) and not is_bare_label(b) for b in group)
        if size < cfg.min_tokens and not exempt:
            pending = group
            continue
        merged.append(group)
    if pending:
        if merged and sum(estimate_tokens(b.text) for b in merged[-1]) + sum(
            estimate_tokens(b.text) for b in pending
        ) <= cfg.max_tokens:
            merged[-1].extend(pending)
        else:
            merged.append(pending)
    return merged


def _naming_block(group: list[Block]) -> Block:
    """Pick the block whose text names the chunk, in priority order.

    1. A leading **bare label** -- ``"**If you smell gas:**"`` is precisely a
       statement of what the chunk is about.
    2. Otherwise the first **anchor** -- so a prohibition folded in behind a
       section intro still yields ``do-not-apply-a-tourniquet`` rather than
       ``every-one-of-these-is-common-in``.
    3. Otherwise the first block.
    """
    if is_bare_label(group[0]):
        return group[0]
    return next((b for b in group if is_anchor(b) and not is_bare_label(b)), group[0])


def pack(blocks: list[Block], cfg: ChunkConfig) -> list[list[Block]]:
    """Expand body blocks into atomic units and group them into child buffers."""
    return _pack(_units(blocks, cfg), cfg)


def naming_block(group: list[Block]) -> Block:
    """The block whose text names a packed group; see :func:`_naming_block`."""
    return _naming_block(group)
