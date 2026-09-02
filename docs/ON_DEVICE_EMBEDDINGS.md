# The Dense Leg on a Phone

Running a 300M-parameter embedding model beside a 2B generator, and how we know
the device computes the same thing the lab does.

---

## The idea that makes it affordable

A phone never embeds a document.

The corpus is fixed and identical on every device, so all 201 passage vectors
are computed once, offline, and ship as a 603 KB file. The only thing that
cannot be precomputed is the query — and that is a single forward pass over
roughly ten tokens.

Sizing the encoder against "embed the corpus at launch" gives one answer;
sizing it against "embed ten tokens per turn" gives a completely different one.
That is the whole trick.

---

## Memory budget

Target: **6 GB minimum, 8 GB recommended.** Budgeted, not yet measured on
hardware — see [TESTING.md](TESTING.md) for what is still open.

| | resident |
|---|---|
| Android OS + system services | ~1.8 GB |
| Gemma 2B IT (INT4, CPU, mmap'd) | ~1.6 GB |
| KV cache (2048-token context) | ~150 MB |
| EmbeddingGemma q4f16 (mmap'd, file-backed) | ~175 MB peak, reclaimable |
| Packed tokenizer tables | ~18 MB |
| Passage vectors | 0.6 MB |
| Flutter engine + Dart heap | ~200 MB |
| SQLite + FTS5 index | ~20 MB |

The encoder's weights live in a `.onnx_data` sidecar that ONNX Runtime
memory-maps, so those pages are **file-backed**: the OS can evict them when
Gemma needs the RAM and fault them back on the next query. That is the
difference between 175 MB of pressure and 175 MB of hard allocation, and it is
why a single self-contained `.onnx` — simpler to ship — would be the worse
choice.

The encoder is also **optional**. Without it the app answers on its two lexical
legs. A degradation, never an outage.

---

## Choosing the model

Measured on the retrieval golden set at passage granularity, PyTorch:

| model | params | Recall@5 | citation R@5 |
|---|---|---|---|
| lexical only | — | 0.815 | 0.599 |
| bge-small-en-v1.5 | 33M | 0.871 | 0.721 |
| multilingual-e5-small | 118M | 0.874 | 0.743 |
| multilingual-e5-base | 278M | 0.888 | 0.771 |
| **EmbeddingGemma-300m** | 308M | **0.897** | **0.849** |

bge-small is a tenth the size for 2.6 points less Recall@5 — but 12.8 points
less citation recall, which is what decides whether the paragraph a user taps
actually contains the answer. EmbeddingGemma also has a Matryoshka head and
genuine multilingual training, both of which matter for a corpus that is going
to grow into Indian languages.

---

## Quantisation: measured, not assumed

The shipped graph is the community `q4f16` ONNX export — 175 MB against 1.2 GB
for the float one. Scored end to end with the graph on **both** sides:

| | Recall@5 | R@20 | MRR | nDCG@5 | cite R@5 |
|---|---|---|---|---|---|
| PyTorch float | 0.897 | 0.979 | 0.771 | 0.758 | 0.849 |
| **ONNX q4f16 (ships)** | **0.897** | **0.982** | **0.758** | **0.750** | **0.846** |

Neutral on the headline metric, marginally better in the tail, marginally worse
in the ordering. Quantisation costs nothing here.

Note that per-vector cosine agreement between the two is only **0.978** — the
graph is genuinely a different model. It does not matter, because both sides of
the comparison use the same one; what would matter is mixing them, which is
exactly the trap below.

---

## Two traps that cost real time, both silent

### The vector cache was keyed by model but not backend

The lab caches document vectors on disk keyed by content hash, under a filename
built from the model key and dimension. A quantised export is a *different
model*, not a packaging detail — but the filename did not say so, so a run
asked for `--embed-backend onnx` happily reused cached PyTorch document vectors
and scored them against ONNX queries.

That reported **Recall@5 90.0% for a configuration no device can run.** The
honest number is 89.7%. The cache key now includes the backend.

### The exported graph does not fully mask padding

The same text embedded alone and embedded beside a longer one comes back at
**cosine 0.998**, not 1.0. So batching made a document's vector depend on which
other documents happened to share its batch — irreproducible run to run, and
impossible for a phone to match, because a phone embeds exactly one query at a
time.

`OnnxEmbedder` encodes one row per pass. Slower in the lab, and the only way
the lab and the device compute the same thing. **Do not re-enable padding for
speed.**

---

## Tokenizing Gemma in Dart

The device has to tokenize the query, and Gemma's `tokenizer.json` is 33 MB of
JSON with 262,144 vocabulary entries and 514,906 merges. Parsing that at launch
is not affordable, and almost all of it is dead weight for encoding.

**BPE only needs strings for its first step.** Once each character has become
an id, every merge is a pair of ids producing a third. So the packer
pre-resolves the merge table to ids and ships only the 19,227 single-character
entries:

```
magic "GBPE" | version | char_count | merge_count
bos | eos | unk | byte_base | blob_len
char_offsets[] | char_blob | char_ids[]
merge_left[] | merge_right[] | merge_result[]      ← rank is the array index
```

6.1 MB, and everything after the first loop is integer work. On the Dart side
the merge table is an open-addressed `Int64List` keyed by `(left << 32) | right`
— a `Map` of half a million entries would cost far more in boxed objects than
three typed arrays.

Two details that are easy to get wrong and produce no error:

- **Normalisation.** Gemma replaces every space with `U+2581`, then
  pre-tokenizes by splitting on a space that no longer exists. The whole string
  therefore reaches BPE as one piece; there is no word-boundary pass to
  reproduce.
- **Byte fallback.** Characters outside the vocabulary become their UTF-8 bytes,
  not `<unk>`. Without it, a Devanagari query collapses to nothing and the
  vector carries no signal.

### Task prefixes are not decoration

EmbeddingGemma is trained with asymmetric prefixes — `task: search result |
query: ` and `title: none | text: `. A query encoded without its prefix lands
somewhere else in the space than the documents it is compared against. The
prefix travels in the vector manifest rather than being retyped at the call
site, so it cannot drift from the vectors it belongs to.

---

## The artifacts are one set

Built by one command, meaningful only together:

```bash
python3 -m survive_rag pack --tokenizer <path to embeddinggemma tokenizer.json>
python3 -m evals parity   # regenerates the Dart parity fixture
```

| file | size | shipped how |
|---|---|---|
| `assets/index/corpus.json` | 579 KB | bundled |
| `assets/index/passages.f32` | 603 KB | bundled |
| `assets/index/passages.f32.json` | 8 KB | bundled |
| `assets/index/tokenizer.bin` | 6.1 MB | bundled |
| `model_q4f16.onnx` + `.onnx_data` | 175 MB | **downloaded** |

A vector file built against a different chunking would still load, still have
plausible dimensions, and pair every passage with a stranger's embedding —
with no symptom other than retrieval being mysteriously worse. The manifest
carries the passage ids and the loader checks them.

The 175 MB graph is downloaded over the same manifest and resumable path as the
generator, and offered in Settings as an upgrade rather than a requirement.
Stacking a second large download in front of someone who may need the app today
is the wrong trade. Both files must land in `models/` under exactly the names
in `OnnxEmbeddingService`; a graph without its sidecar opens far enough to look
healthy and fails at the first inference.

---

## Proving the device matches the lab

The app is a second implementation of a pipeline measured in Python: same
chunks, same vectors, same fusion, different language. **Every way the two can
disagree is silent** — a retyped RRF weight, a missing task prefix, a
transliterated query reaching the dense leg anyway. None of them throw. They
just make the device worse than the report, which is the one failure an eval by
construction cannot see.

Two tests close that gap. Details in [TESTING.md](TESTING.md); the headline is
that the Dart dense leg reproduces the lab's cosines to a worst-case difference
of **6.04e-7**.

That test earned its keep immediately. `Float32List.buffer` returns the whole
backing store, not the view's window — so every passage was storing the entire
603 KB vector file as its own embedding. Cosine saw mismatched lengths,
returned 0.0 for every pair, and the dense leg ranked every query identically.
No error anywhere.

---

## Related

- [RETRIEVAL.md](RETRIEVAL.md) — how the leg fits into the pipeline
- [TESTING.md](TESTING.md) — the parity strategy, and what is still unverified
- [RESULTS.md](RESULTS.md) — every measured number
