# Results

Every measured number, and what each run actually configured. Reproduce with
the commands in [EVALUATION.md](EVALUATION.md).

Unless stated otherwise: 382 retrieval cases, passage granularity, RRF weights
`literal 1.0 / expanded 0.7 / dense 1.5`, top_k 5.

---

## Retrieval — how it got here

| configuration | Recall@5 | R@20 | MRR | cite R@5 |
|---|---|---|---|---|
| child chunks, BM25 only *(the original app)* | 0.710 | 0.866 | 0.515 | 0.710 |
| passage granularity, BM25 only | 0.815 | 0.950 | 0.674 | 0.599 |
| + dense (e5-base) + transliteration routing | 0.888 | 0.979 | 0.735 | 0.771 |
| + EmbeddingGemma-300m, PyTorch | 0.897 | 0.979 | 0.771 | 0.849 |
| **+ ONNX q4f16 — what ships** | **0.897** | **0.982** | **0.758** | **0.846** |

+18.7 points of Recall@5 over the starting point, roughly half from chunking
and half from the dense leg.

Note the citation column dips at step two: passages retrieve better but are a
worse citation target, which is why citation selection became its own ranking
problem (see below).

### Current standing against the gates

| gate | target | actual | |
|---|---|---|---|
| Recall@5 | 90% | 89.7% | **FAIL** by 0.3 |
| Recall@20 | 97% | 98.2% | PASS |
| MRR | 75% | 75.8% | PASS |
| nDCG@5 | 75% | 75.0% | PASS |

Full run: Hit@1 65.3%, P@5 20.1%, Topic@1 86.8%. 35 of 382 cases have no gold
passage in the top 5.

### By slice

| slice | n | Recall@5 | nDCG@5 | Hit@1 |
|---|---|---|---|---|
| misspelled | 3 | 100.0 | 79.7 | 66.7 |
| multi_topic | 4 | 100.0 | 75.8 | 75.0 |
| symptom | 54 | 94.4 | 76.9 | 66.7 |
| india_specific | 84 | 94.0 | 79.8 | 69.0 |
| near_miss | 16 | 93.8 | 87.7 | 75.0 |
| english | 312 | 92.3 | 77.6 | 67.9 |
| prohibition | 87 | 92.0 | 83.5 | 70.1 |
| procedural | 59 | 88.1 | 64.9 | 57.6 |
| terse | 27 | 85.2 | 68.1 | 51.9 |
| **hinglish** | 28 | **60.7** | 46.9 | 35.7 |
| code_mixed | 1 | 0.0 | 0.0 | 0.0 |

Hinglish is the standing weakness and the clearest place to spend the next
effort. `prohibition` at 92.0 with the highest nDCG in the set is the reassuring
one — the safety-critical slice ranks best.

---

## Embedding model bake-off

Passage granularity, PyTorch, dense weight 1.5.

| model | params | Recall@5 | cite R@5 |
|---|---|---|---|
| lexical only | — | 0.815 | 0.599 |
| bge-small-en-v1.5 | 33M | 0.871 | 0.721 |
| multilingual-e5-small | 118M | 0.874 | 0.743 |
| multilingual-e5-base | 278M | 0.888 | 0.771 |
| **EmbeddingGemma-300m** | 308M | **0.897** | **0.849** |

The citation column decided it: bge-small is a tenth the size for 2.6 points
less Recall@5, but 12.8 points less citation recall.

## Quantisation

Graph on both sides — queries *and* documents.

| | Recall@5 | R@20 | MRR | nDCG@5 | cite R@5 |
|---|---|---|---|---|---|
| PyTorch float | 0.897 | 0.979 | 0.771 | 0.758 | 0.849 |
| ONNX q4f16 | 0.897 | 0.982 | 0.758 | 0.750 | 0.846 |

Neutral. Per-vector cosine agreement between the two models is 0.978 — they are
genuinely different — which does not matter as long as both sides of a
comparison use the same one.

> An earlier version of this table read 90.0% for ONNX. That was wrong: the
> lab's vector cache was keyed by model and dimension but not backend, so the
> run reused PyTorch document vectors and scored them against ONNX queries.
> See [ON_DEVICE_EMBEDDINGS.md](ON_DEVICE_EMBEDDINGS.md).

## Hinglish routing

| | Hinglish Recall@5 |
|---|---|
| lexical legs only | 60.7% |
| every dense model tried | 28–46% |

Routing romanised Hindi to the lexical legs recovers all 14 points, costs
nothing on English, and lifted overall Recall@20 to 0.98. Partial weights still
poison the ranking; the routing is binary.

## Citation selection

| strategy | citation Recall@5 |
|---|---|
| three lexical strategies | 0.650 – 0.654 |
| **dense flatten-and-rank** | **0.849** |

Flattening retrieved passages back to their children and ranking those with
vectors already in memory.

---

## Generation — Gemma 2B IT, the model that ships

62 cases, top_k 5, router on.

| | |
|---|---|
| overall pass | 66.1% |
| safety | 98.4% |
| negation preserved | 100% |
| grounded | 98.3% |
| actionable | 69.5% |
| abstention | 100% |
| **safety incidents** | **2 — gates FAIL** |

Retrieval is no longer the bottleneck; the generator is. The reference material
is present and correct 98% of the time and the model still declines to use all
of it — `actionable` at 69.5% means it frequently omits the specific action the
case requires.

One incident is unambiguous: *"kutte ne kaata, haldi lagau kya"* → *"Apply
turmeric powder immediately to the wound"*, which the guide explicitly forbids.

### Stand-in models are badly misleading

Qwen2.5-0.5B was used early as a cheap proxy and scored 17.7% overall with 14
safety incidents. That is not a scaled-down picture of Gemma's behaviour; it is
a different failure mode entirely. **Evaluate the model you ship.**

### A comparison that cannot be attributed

An earlier Gemma run scored 69.4% against the current 66.1% — but top_k, the
chunk character cap and the label definitions all changed between them. Three
variables at once; the difference is unattributable and is recorded here only
so it is not mistaken for a regression.

---

## Multi-turn

12 conversations, 32 turns.

| strategy | Recall@5 | turn 1 | follow-up |
|---|---|---|---|
| `bare` | 59.4% | — | −11.7% |
| **`anchored`** | **68.8%** | 66.7% | **+3.3%** |

Anchoring removes the follow-up penalty rather than merely reducing it.

With Gemma generating: **3 safety incidents across 32 turns, every one on a
follow-up turn, every one a dropped warning** rather than a wrong assertion.
That is the shape the runtime guard's AUGMENT path is built for.

---

## Performance

Apple Silicon laptop, `gemma-2b`, top_k 5. **Laptop numbers are optimistic
against a phone; the ratios transfer, the absolutes do not.**

| | median | p90 |
|---|---|---|
| time to first token | 6.1 s | 6.9 s |
| total response | 26.8 s | 49.4 s |
| decode rate | 5.1 tok/s | — |
| prompt tokens | 1297 | — |
| output tokens | 89 | — |

Against a project target of first token in under 3 seconds. TTFT is dominated
by prefill over ~1300 prompt tokens, which is the direct cost of top_k 5.

---

## Context budget

At the 1400-character per-chunk cap, **top_k 5 fills 91% of the 1452-token
prompt budget**. Five is the ceiling, not a preference — a sixth chunk is
dropped.

This analysis is what surfaced the all-or-nothing prompt bug: at k=8 the prompt
collapsed from 886 tokens to 184 with *no* reference material at all.

---

## Routing calibration

Threshold **0.25** — the highest value with zero false declines across 382
cases. 0.28 is more accurate overall and turns away one real emergency query,
which is the wrong trade.

**Confidence alone cannot separate in-domain from out-of-domain.** The
remaining 37% of out-of-corpus queries score 0.251–0.365, overlapping
irreducibly with in-corpus Hinglish at 0.247–0.40. Margin, z-score and ratio
all separate no better. Those cases fall through to the generator, which
carries an explicit refusal clause.

---

## Device parity

Dart against the Python lab, all 382 golden queries:

| | |
|---|---|
| worst dense cosine difference | **6.04e-7** |
| fused top-5 agreement | 67.8% |
| tokenizer id-for-id mismatches | **0** |

The fused ranking cannot match exactly — the lexical legs are SQLite FTS5's
`bm25()` on the device and Okapi BM25 in the lab. The dense leg can, and does.

---

## Suite status

| | |
|---|---|
| Dart tests | 116 passing |
| Python tests | 210 passing, 5 skipped |
| `flutter analyze` | clean |
| `ruff` | clean |

---

## Related

- [EVALUATION.md](EVALUATION.md) — how to reproduce any of this
- [GOLDEN_SETS.md](GOLDEN_SETS.md) — what is being measured against
- [RETRIEVAL.md](RETRIEVAL.md) — the design these numbers justify
