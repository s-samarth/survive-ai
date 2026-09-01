"""Chunking behaviour, including the rules that were wrong on the first pass."""

from __future__ import annotations

from survive_rag.corpus.chunker import ChunkConfig, chunk_guide, is_prohibition
from survive_rag.corpus.markdown_blocks import parse_blocks

GUIDE = """# Test Guide

Intro paragraph that frames the whole document.

---

## Part 1: Things

Lead-in sentence for part one.

**1. First Item (label)**
- detail one about the first item, long enough to matter here
- detail two about the first item, also reasonably long

**2. Second Item (label)**
- detail one about the second item, long enough to matter here

## Part 2: Prohibitions

Every one of these is common and every one causes harm.

- **DO NOT apply a tourniquet.** It causes limb ischaemia and gangrene.
- **DO NOT cut the bite site.** It causes uncontrollable bleeding.

**Immediately:**
1. **Do not light anything.** Gas leaks are almost universal after a collapse.
2. Cover your mouth with cloth.
"""


def test_sections_become_parents() -> None:
    parents, _ = chunk_guide(GUIDE, "test")
    titles = [p.title for p in parents]
    assert titles == ["Overview", "Part 1: Things", "Part 2: Prohibitions"]


def test_content_before_first_section_is_not_lost() -> None:
    _, children = chunk_guide(GUIDE, "test")
    overview = [c for c in children if "#overview#" in c.chunk_id]
    assert overview and "frames the whole document" in overview[0].text


def test_bold_label_starts_its_own_child() -> None:
    """Each labelled sub-topic must be separately retrievable."""
    _, children = chunk_guide(GUIDE, "test")
    ids = [c.chunk_id for c in children]
    assert any("first-item-label" in i for i in ids)
    assert any("second-item-label" in i for i in ids)


def test_label_keeps_its_own_bullets() -> None:
    _, children = chunk_guide(GUIDE, "test")
    first = next(c for c in children if "first-item-label" in c.chunk_id)
    assert "detail one about the first item" in first.text
    assert "second item" not in first.text


def test_each_prohibition_is_its_own_child() -> None:
    """The highest-stakes lines must each be independently citable."""
    _, children = chunk_guide(GUIDE, "test")
    ids = [c.chunk_id for c in children]
    assert any("do-not-apply-a-tourniquet" in i for i in ids)
    assert any("do-not-cut-the-bite-site" in i for i in ids)


def test_prohibition_named_even_when_folded_behind_an_intro() -> None:
    """The section intro is a runt and merges forward; the id must still
    name the prohibition, not the intro."""
    _, children = chunk_guide(GUIDE, "test")
    merged = next(c for c in children if "every one of these" in c.text.lower())
    assert "do-not-apply-a-tourniquet" in merged.chunk_id


def test_bare_label_keeps_the_list_beneath_it() -> None:
    """``**Immediately:**`` alone is meaningless; it must carry its steps."""
    _, children = chunk_guide(GUIDE, "test")
    label = next(c for c in children if c.chunk_id.endswith("#immediately"))
    assert "Do not light anything" in label.text


def test_prohibitions_are_flagged() -> None:
    _, children = chunk_guide(GUIDE, "test")
    tourniquet = next(c for c in children if "tourniquet" in c.chunk_id)
    assert tourniquet.is_prohibition
    assert not is_prohibition("Cover your mouth with cloth.")


def test_line_numbers_point_back_at_the_source() -> None:
    """Citations deep-link by line, so spans must be real and ordered."""
    lines = GUIDE.splitlines()
    _, children = chunk_guide(GUIDE, "test")
    for child in children:
        assert 1 <= child.line_start <= child.line_end <= len(lines)
        assert lines[child.line_start - 1].strip()


def test_every_child_belongs_to_a_real_parent() -> None:
    parents, children = chunk_guide(GUIDE, "test")
    ids = {p.parent_id for p in parents}
    assert all(c.parent_id in ids for c in children)
    for parent in parents:
        assert parent.child_ids


def test_config_changes_granularity() -> None:
    _, fine = chunk_guide(GUIDE, "test", ChunkConfig(min_tokens=10, target_tokens=40))
    _, coarse = chunk_guide(
        GUIDE,
        "test",
        ChunkConfig(min_tokens=300, target_tokens=400, max_tokens=600,
                    explode_lists=False, anchor_flush=False),
    )
    assert len(fine) > len(coarse)


def test_rule_lines_are_not_emitted_as_blocks() -> None:
    assert all(b.kind != "rule" for b in parse_blocks(GUIDE))
