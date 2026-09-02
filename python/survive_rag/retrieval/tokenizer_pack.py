"""Pack Gemma's BPE tokenizer into a form Dart can read without a JSON parser.

The device has to tokenise the query, because the query is the one thing that
cannot be embedded ahead of time. Gemma's ``tokenizer.json`` is 33 MB and
262 144 vocabulary entries -- parsing that at launch on the 6 GB phones this
targets is not affordable, and most of it is dead weight for encoding.

The trick is that BPE only needs strings at the very first step. Once each
character has become an id, every merge is a pair of ids producing a third id,
so if the merge table is pre-resolved to ids the encoder is pure integer work.
That drops the string table from 262 144 entries to the 19 227 single-character
ones, and turns the merge list into three parallel ``uint32`` arrays.

Layout, little-endian throughout::

    magic        4 bytes  "GBPE"
    version      u32      == FORMAT_VERSION
    char_count   u32
    merge_count  u32
    bos_id       u32
    eos_id       u32
    unk_id       u32
    byte_base    u32      id of "<0x00>"; byte N is byte_base + N
    blob_len     u32
    char_offsets u32 x (char_count + 1)   byte offsets into char_blob
    char_blob    utf-8 characters, ascending by id
    char_ids     u32 x char_count
    merge_left   u32 x merge_count        rank is the array index
    merge_right  u32 x merge_count
    merge_result u32 x merge_count

Verified against ``tokenizers`` on the full retrieval golden set plus
Devanagari, emoji and whitespace edge cases; see ``tests/test_tokenizer_pack``
and the Dart-side parity fixture this module also writes.
"""

from __future__ import annotations

import json
import struct
from pathlib import Path

MAGIC = b"GBPE"
FORMAT_VERSION = 1

# The normaliser Gemma declares is a single Replace of " " with U+2581. The
# pre-tokeniser then splits on " ", which no longer occurs, so the whole string
# reaches BPE as one piece -- there is no word-boundary step to reproduce.
SPACE = "▁"


def _load(tokenizer_json: Path) -> dict:
    """Read ``tokenizer.json`` and check it is the BPE shape we support.

    Args:
        tokenizer_json: Path to a Hugging Face ``tokenizer.json``.

    Returns:
        The decoded document.

    Raises:
        ValueError: If the tokeniser is not byte-fallback BPE, or declares
            options this packer does not reproduce.
    """
    doc = json.loads(tokenizer_json.read_text(encoding="utf-8"))
    model = doc["model"]
    if model.get("type") != "BPE":
        raise ValueError(f"expected a BPE tokeniser, found {model.get('type')!r}")
    if not model.get("byte_fallback"):
        raise ValueError("expected byte_fallback; unknown characters would become <unk>")
    for flag in ("dropout", "continuing_subword_prefix", "end_of_word_suffix"):
        if model.get(flag):
            raise ValueError(f"unsupported tokeniser option {flag}={model[flag]!r}")
    if model.get("ignore_merges"):
        raise ValueError("unsupported tokeniser option ignore_merges=True")
    return doc


def _merge_arrays(
    vocab: dict[str, int], merges: list[list[str]]
) -> tuple[list[int], list[int], list[int]]:
    """Resolve the merge table from strings to ids.

    Only the first occurrence of a pair is kept: rank is position in the list,
    and a later duplicate could never win.

    Args:
        vocab: Token string to id.
        merges: Ordered ``[left, right]`` pairs.

    Returns:
        Parallel ``(left, right, result)`` id lists.

    Raises:
        ValueError: If a merge half or its concatenation is not in the vocab,
            which would leave the encoder unable to name the merged token.
    """
    seen: set[tuple[int, int]] = set()
    left: list[int] = []
    right: list[int] = []
    result: list[int] = []
    for a, b in merges:
        try:
            key = (vocab[a], vocab[b])
            merged = vocab[a + b]
        except KeyError as exc:  # pragma: no cover - guards a corrupt vocab
            raise ValueError(f"merge {a!r}+{b!r} names a token outside the vocab") from exc
        if key in seen:
            continue
        seen.add(key)
        left.append(key[0])
        right.append(key[1])
        result.append(merged)
    return left, right, result


def _u32(values: list[int]) -> bytes:
    """Pack a list of ids as little-endian ``uint32``."""
    return struct.pack(f"<{len(values)}I", *values)


def pack_tokenizer(tokenizer_json: Path, destination: Path) -> Path:
    """Write the packed tokenizer the Flutter app loads.

    Args:
        tokenizer_json: Path to a Hugging Face ``tokenizer.json``.
        destination: Output ``.bin`` path; parent directories are created.

    Returns:
        The path written.
    """
    doc = _load(tokenizer_json)
    vocab: dict[str, int] = dict(doc["model"]["vocab"])
    left, right, result = _merge_arrays(vocab, doc["model"]["merges"])

    chars = sorted(((k, v) for k, v in vocab.items() if len(k) == 1), key=lambda kv: kv[1])
    blob = b""
    offsets = [0]
    for text, _ in chars:
        blob += text.encode("utf-8")
        offsets.append(len(blob))

    destination.parent.mkdir(parents=True, exist_ok=True)
    with destination.open("wb") as out:
        out.write(MAGIC)
        out.write(
            struct.pack(
                "<8I",
                FORMAT_VERSION,
                len(chars),
                len(left),
                vocab["<bos>"],
                vocab["<eos>"],
                vocab["<unk>"],
                vocab["<0x00>"],
                len(blob),
            )
        )
        out.write(_u32(offsets))
        out.write(blob)
        out.write(_u32([i for _, i in chars]))
        out.write(_u32(left))
        out.write(_u32(right))
        out.write(_u32(result))
    return destination
