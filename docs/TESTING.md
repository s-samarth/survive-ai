# Testing

What is proven, how it is proven, and what is still open.

---

## The core problem

The app is a **second implementation** of a pipeline that was measured in
Python. Same chunks, same vectors, same fusion weights — different language.

Every way the two can disagree is silent. A retyped RRF weight. A missing task
prefix. A transliterated query reaching the dense leg anyway. A tokenizer that
splits one subword differently. None of them throw; they produce a plausible
vector in the wrong place and make the device quietly worse than the report.

That is the one failure an eval cannot see by construction, because the eval
only ever runs the Python side.

---

## Running things

```bash
flutter test                    # 116 tests
flutter analyze                 # zero warnings enforced
flutter test test/services/retrieval_parity_test.dart

cd python
.venv/bin/python -m pytest -q   # 210 tests
.venv/bin/ruff check .
```

> `assets/index/` is gitignored as generated output. The parity and tokenizer
> tests **skip** rather than fail when it is absent, so a green suite on a fresh
> clone does not mean they ran. Build the artifacts first:
> `python3 -m survive_rag pack --tokenizer <tokenizer.json>` and
> `python3 -m evals parity`.

---

## The two parity tests

### Tokenizer — exact

`test/services/gemma_tokenizer_test.dart` checks the Dart BPE port **id for id**
against the Python encoder that produced the shipped vectors, over all 382
golden queries plus deliberate edge cases: Devanagari, emoji, repeated
whitespace, the empty string, a 200-character run, and both task prefixes.

A wrong subword split does not throw. It produces a perfectly reasonable vector
somewhere else in the space. This is the only cheap way to catch it.

### Retrieval — scores exactly, ranking approximately

`test/services/retrieval_parity_test.dart` replays the whole golden set through
the **real** Dart retriever — real `DatabaseService`, real FTS5, real index
loader, real RRF — with the ONNX call replaced by query vectors Python
computed.

It asserts two different things, for two different reasons:

| | assertion | why |
|---|---|---|
| dense leg | cosines match to **1e-5** | fully determined: same vectors, same arithmetic |
| fused ranking | ≥60% top-5 overlap | *cannot* match exactly |

**Scores, not ranks, for the dense leg.** Cosines over one corpus cluster
tightly enough that a 1e-7 float difference reorders near-ties, so an ordering
assertion would fail on arithmetic that is entirely correct. The observed worst
case is 6.04e-7, so the 1e-5 threshold has sixteen times the headroom and still
sits four orders of magnitude below any real defect — a missing task prefix
moves a score by ~0.05, a mispaired vector by ~0.5.

**Overlap, not equality, for the fusion.** The lexical legs are SQLite FTS5's
`bm25()` on the device and Okapi BM25 in the lab: same family, different
stemmers, different stopword lists, different tie-breaking. Demanding equality
there would only teach us to delete the test. Observed agreement is 67.8%.

The mock is honest about its scope: it stands in for the one part already
proven separately — the exported graph agrees with PyTorch, and the Dart
tokenizer agrees with the Python one. What it leaves under test is everything
around it.

### It earned its keep immediately

It caught `Float32List.buffer` returning the whole backing store rather than
the view's window, so every passage was storing the entire 603 KB vector file
as its own embedding. Cosine saw mismatched lengths, returned 0.0 for every
pair, and the dense leg ranked every query identically — with no error
anywhere.

---

## Test through the real class, not around it

`DatabaseService` takes an optional `databasePath` so tests can drive it
directly. This exists because of a specific failure:

The database tests built the schema **by hand** and ran SQL against their own
copy. So `insertChunks`, `deleteChunksForDoc` and `searchFts` were never
executed by anything. All three named a `chunk_id` column that `chunks_fts`
does not have — it is an external-content FTS5 table over `topic`,
`heading_path`, `body`. Every one raised against the real schema.

**Keyword retrieval was dead on the device while the entire suite was green.**

`test/services/database_fts_test.dart` now drives the real class end to end. A
test that reimplements the thing it is testing is testing the reimplementation.

Two further notes from that work:

- Use a temp **file** per test, not `inMemoryDatabasePath` — sqflite_ffi hands
  the same in-memory database to every connection, so rows leak between tests.
- The triggers are the only writer to `chunks_fts`. Never insert into it
  directly, and never use `ConflictAlgorithm.replace` on `chunks` — REPLACE
  skips DELETE triggers, orphaning the old index row and appending a duplicate.

---

## What is still unverified

The plugin call itself has **never executed**. Three questions need hardware:

1. **Does ONNX Runtime load a 175 MB external-data graph under Flutter?** The
   one line of the dense leg with no test behind it.
2. **Does it fit beside Gemma on a 6 GB phone?** The memory-mapping argument in
   [ON_DEVICE_EMBEDDINGS.md](ON_DEVICE_EMBEDDINGS.md) is sound but unmeasured.
3. **What does it cost in time to first token?**

Everything else — chunking, vectors, tokenization, cosine, fusion, routing,
FTS, prompt budgeting, the safety guard — is covered without a device.

---

## Getting to a device

| approach | cost | answers |
|---|---|---|
| **Android command-line tools** (no Android Studio) | ~2–3 GB | 1 and 3 |
| **Cloud device farm** (Firebase Test Lab, BrowserStack) | none local | 1, 2 and 3 |
| macOS desktop target | full Xcode + CocoaPods | 1 only; Gemma will not run there |

Recommended: command-line tools locally for the fast loop, one device-farm run
before release for the memory question. An emulator approximates memory
behaviour; it does not settle it.

```bash
brew install --cask temurin android-commandlinetools
sdkmanager "platform-tools" "platforms;android-35" "emulator" \
           "system-images;android-35;google_apis;arm64-v8a"
```

---

## Related

- [EVALUATION.md](EVALUATION.md) — the Python-side harness
- [ON_DEVICE_EMBEDDINGS.md](ON_DEVICE_EMBEDDINGS.md) — what the parity tests protect
- [RESULTS.md](RESULTS.md) — current numbers
