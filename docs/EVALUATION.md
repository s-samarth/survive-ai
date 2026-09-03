# The Evaluation Harness

`python/evals/` measures the system. It never ships.

---

## Why it is a separate program

```
python/survive_rag/   the reference implementation of what SHIPS
python/evals/         golden sets, metrics, model backends, reports
```

The dependency runs one way: `evals` imports `survive_rag`, never the reverse.
`tests/test_architecture.py` enforces that, along with the lazy-import rule that
keeps the lexical path free of third-party packages, and a 200-line limit on
every module.

The separation is not tidiness. The lab needs PyTorch, `sentence-transformers`
and a 27 GB generator; the shipped path needs none of it. Mixing them is how a
`torch` import ends up on the query path, and how "we measured it" quietly stops
meaning "we measured what ships".

---

## Four harnesses

Each answers a different question, and the answers are not interchangeable.

| harness | question | command |
|---|---|---|
| **retrieval** | Was the answer *available* in the prompt? | `evals eval` |
| **generation** | What did the model *do* with it? | `evals gen-eval` |
| **multi-turn** | Does it survive a follow-up? | `evals multiturn` |
| **performance** | How long does the user wait? | `evals perf` |

Plus two diagnostics: `evals context` (how much of the token budget the prompt
actually uses) and `evals route` (threshold calibration).

---

## Commands

```bash
python3 -m evals validate                     # every golden set against the live corpus
python3 -m evals eval --dense                 # the retrieval eval
python3 -m evals eval --sweep models --html reports/models.html
python3 -m evals gen-eval --model gemma-2b    # generation, on the model that ships
python3 -m evals multiturn                    # conversational resilience
python3 -m evals perf --model gemma-2b        # TTFT, decode rate
python3 -m evals context                      # prompt budget occupancy
python3 -m evals route --calibrate            # abstention threshold
python3 -m evals parity                       # the Dart parity fixture
```

To score what actually ships rather than the lab's convenience configuration:

```bash
python3 -m evals eval --dense --embed-model embeddinggemma --embed-backend onnx
```

`validate` runs first in CI. A guide edit that invalidates a hand-authored
label must fail loudly there rather than quietly depressing every score in the
next report.

---

## Metrics, and what each is for

**Retrieval**

| metric | reads as |
|---|---|
| Recall@5 | did the answer reach the prompt at all — the headline |
| Recall@20 | is the candidate set good enough for a reranker to ever help |
| MRR / nDCG@5 | is the *ordering* good, which matters because the prompt is budget-limited |
| Hit@1 | how often the first passage alone would do |
| Topic@1 | is the router pointing at the right guide |
| citation Recall@5 | does the paragraph a user taps contain the answer |

**Generation** — safety failures are counted and listed separately, never
averaged into a quality score. One answer in a hundred recommending a
tourniquet is not a 99% pass; it is an incident.

| check | reads as |
|---|---|
| safety | the answer never *asserts* something the guides forbid (critical) |
| negation | a warning the guides carry is preserved (critical) |
| grounded | the answer's content traces to its reference material |
| actionable | the answer names the specific action the case requires |
| abstention | an out-of-corpus query is declined rather than guessed at |

---

## Release gates

```
recall_at_5   >= 90%
recall_at_20  >= 97%
mrr           >= 75%
ndcg_at_5     >= 75%
safety incidents == 0
negation preserved == 100%
overall pass  >= 85%
```

`--strict` exits non-zero when a gate fails; `--check-regressions` exits
non-zero when any metric falls below the recorded baseline in
`evals/baselines/`. Current standing is in [RESULTS.md](RESULTS.md) — retrieval
misses one gate by 0.3 points and generation fails on two safety incidents.

---

## Span-resolved labels

Golden labels name chunk ids, but ids depend on the chunking policy — so a
label set written against 90-token children would be worthless the moment
scoring moved to 320-token passages.

Instead, labels resolve **once** against a reference corpus into markdown line
spans, and matching afterwards is by line overlap. One label set therefore
scores any chunking policy, any granularity, and any future re-chunk without
being rewritten. This is what made it possible to compare child / passage /
parent granularity honestly rather than re-labelling three times and hoping.

---

## Sweeps and baselines

`evals eval --sweep <name>` runs a named A/B — `models` for the embedding
bake-off, and others in `evals/sweeps.py`. Reports render to text or HTML.

`--save-baseline` records a run in `evals/baselines/`, and `--baseline <name>`
selects which one. There are two for retrieval, because they answer to
different runners:

| baseline | configuration | who compares against it |
|---|---|---|
| `retrieval` | lexical legs only | CI, on every push |
| `retrieval-shipping` | EmbeddingGemma, ONNX, dense on | the lab |

CI cannot run the dense leg — that needs model downloads that do not belong in
a per-push job — so pointing it at the shipping numbers would produce a wall of
regressions against a configuration it never had the models to reproduce, and
teach everyone to ignore the report. CI runs with `--check-regressions`, so a
real lexical regression fails the build.

---

## Honest limits of this harness

- **Laptop numbers are optimistic.** `perf` runs on Apple Silicon. The ratios
  transfer to a phone; the absolute figures do not.
- **Generation gates are checked by pattern matching**, not a judge model.
  Negation checks are cue-based and clause-anchored, which is why two of four
  early "safety incidents" turned out to be harness bugs rather than model
  failures — see [GOLDEN_SETS.md](GOLDEN_SETS.md).
- **Nothing here runs on a device.** Device parity is a Dart concern; see
  [TESTING.md](TESTING.md).

---

## Related

- [GOLDEN_SETS.md](GOLDEN_SETS.md) — how the labels were built
- [RESULTS.md](RESULTS.md) — every number this harness has produced
- [RETRIEVAL.md](RETRIEVAL.md) — what is being measured
