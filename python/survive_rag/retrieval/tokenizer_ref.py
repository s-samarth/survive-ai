"""Reference reader and encoder for the packed Gemma tokenizer.

This is the specification the Dart port implements. It reads the artifact
:mod:`survive_rag.retrieval.tokenizer_pack` writes -- not ``tokenizer.json`` --
so a packing bug shows up here rather than hiding behind a source of truth the
device never sees.

The encoder is asserted equal to Hugging Face ``tokenizers`` over the full
retrieval golden set in the Python tests, and its output is the fixture the
Dart tests check against. Those two links are what let a Dart tokeniser be
trusted with vectors that must land in the same space as embeddings computed
offline by a completely different implementation.
"""

from __future__ import annotations

import struct
from dataclasses import dataclass
from pathlib import Path

from .tokenizer_pack import FORMAT_VERSION, MAGIC, SPACE


@dataclass(frozen=True, slots=True)
class PackedTokenizer:
    """The packed tables, resolved into dictionaries for the reference path.

    Attributes:
        chars: Single character to token id.
        rank: ``(left_id, right_id)`` to merge rank; lower merges first.
        result: ``(left_id, right_id)`` to the id of the merged token.
        bos: Beginning-of-sequence id.
        eos: End-of-sequence id.
        byte_base: Id of ``<0x00>``; byte ``n`` is ``byte_base + n``.
    """

    chars: dict[str, int]
    rank: dict[tuple[int, int], int]
    result: dict[tuple[int, int], int]
    bos: int
    eos: int
    byte_base: int


def read_packed(path: Path) -> PackedTokenizer:
    """Load a ``.bin`` written by :func:`~.tokenizer_pack.pack_tokenizer`.

    Args:
        path: The packed tokenizer artifact.

    Returns:
        The tables ready for :func:`encode`.

    Raises:
        ValueError: If the magic or format version is not recognised.
    """
    raw = path.read_bytes()
    if raw[:4] != MAGIC:
        raise ValueError(f"not a packed tokenizer: magic {raw[:4]!r}")
    version, char_count, merge_count, bos, eos, _unk, byte_base, blob_len = struct.unpack_from(
        "<8I", raw, 4
    )
    if version != FORMAT_VERSION:
        raise ValueError(f"unsupported packed tokenizer version {version}")

    at = 36
    offsets = struct.unpack_from(f"<{char_count + 1}I", raw, at)
    at += 4 * (char_count + 1)
    blob = raw[at : at + blob_len]
    at += blob_len
    char_ids = struct.unpack_from(f"<{char_count}I", raw, at)
    at += 4 * char_count

    def take(n: int) -> tuple[int, ...]:
        nonlocal at
        out = struct.unpack_from(f"<{n}I", raw, at)
        at += 4 * n
        return out

    left, right, result = take(merge_count), take(merge_count), take(merge_count)

    chars = {
        blob[offsets[i] : offsets[i + 1]].decode("utf-8"): char_ids[i]
        for i in range(char_count)
    }
    pairs = list(zip(left, right, strict=True))
    return PackedTokenizer(
        chars=chars,
        rank={pair: i for i, pair in enumerate(pairs)},
        result=dict(zip(pairs, result, strict=True)),
        bos=bos,
        eos=eos,
        byte_base=byte_base,
    )


def encode(text: str, tokenizer: PackedTokenizer) -> list[int]:
    """Encode ``text`` to token ids, wrapped in ``<bos>``/``<eos>``.

    Gemma's normaliser replaces every space with U+2581 and its pre-tokeniser
    then splits on a space that no longer occurs, so the whole string reaches
    BPE as a single piece and there is no word-boundary pass to reproduce.

    Characters outside the vocabulary fall back to their UTF-8 bytes, which is
    what keeps Devanagari, emoji and stray control characters from collapsing
    to ``<unk>`` and stripping a query of its meaning.

    Args:
        text: Raw input, already carrying any task prefix.
        tokenizer: Tables from :func:`read_packed`.

    Returns:
        Token ids for the model.
    """
    ids: list[int] = []
    for ch in text.replace(" ", SPACE):
        found = tokenizer.chars.get(ch)
        if found is not None:
            ids.append(found)
        else:
            ids.extend(tokenizer.byte_base + b for b in ch.encode("utf-8"))

    while len(ids) > 1:
        best_rank, at = None, -1
        for i in range(len(ids) - 1):
            rank = tokenizer.rank.get((ids[i], ids[i + 1]))
            if rank is not None and (best_rank is None or rank < best_rank):
                best_rank, at = rank, i
        if at < 0:
            break
        ids[at : at + 2] = [tokenizer.result[(ids[at], ids[at + 1])]]
    return [tokenizer.bos, *ids, tokenizer.eos]
