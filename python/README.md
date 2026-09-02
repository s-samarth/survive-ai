# survive-rag

Two programs living side by side.

```
survive_rag/   chunking, retrieval, the prompt   -- the reference implementation of what SHIPS
evals/         golden sets, metrics, model
               backends, reports, harnesses      -- the lab. Never ships.
```

**Python is the lab and the build step; Dart is the runtime.** Python cannot go
inside a Flutter APK, so chunking runs here, offline, and emits an index
artifact the app ships and only looks up. That makes this the single source of
truth for chunk ids — which is what stable citations need, because a citation
is only useful if it means the same thing in an eval report, in the database,
and in the guide reader on a phone.

The dependency runs one way: `evals` imports `survive_rag`, never the reverse.
`tests/test_architecture.py` enforces that, along with the lazy-import rule
that keeps the lexical path free of third-party packages, and the 200-line
limit on every module.

## Install

```bash
python3 -m venv .venv && .venv/bin/pip install -e ".[lab]"
```

The lexical retrieval path has **zero** third-party dependencies. The dense leg
needs `numpy` plus `onnxruntime` (the `dense` extra — this is what a device
would carry); the lab adds `sentence-transformers` for measuring candidates
before export.

Two models are gated on Hugging Face and need `hf auth login` plus a licence
accepted on their model page: `google/embeddinggemma-300m` and
`google/gemma-2-2b-it`.

## The two CLIs

```bash
python3 -m survive_rag chunk --export ../assets/index/corpus.json
```

```bash
python3 -m survive_rag query "saanp ne kaat liya" --dense
```

```bash
python3 -m evals validate
```

```bash
python3 -m evals eval --sweep models --html reports/models.html
```

```bash
python3 -m evals gen-eval --model gemma-2b
```

```bash
python3 -m evals multiturn
```

```bash
python3 -m evals context
```

```bash
python3 -m evals perf --model gemma-2b
```

## The three granularities

The corpus is chunked once and read at three sizes, because three consumers
want three different things:

| view | size | who reads it |
|---|---|---|
| **child** | ~90 tokens | the citation target — what the user clicks |
| **passage** | 320 target, 80 overlap | what retrieval scores |
| **parent** | whole `## Part N` | what the model reads |

Scoring at citation granularity was the original mistake: a 30-token
prohibition holds too few terms for BM25 and too little meaning for an
embedding. Passages are windows of consecutive children inside one parent, so
every hit still maps back to an exact child for the citation.

## Retrieval quality

346 hand-authored cases, 12 slices.

| config | R@5 | R@20 | MRR | cite R@5 |
|---|---|---|---|---|
| child chunks, BM25 only (the original) | 0.710 | 0.866 | 0.515 | 0.710 |
| passage granularity, BM25 only | 0.815 | 0.950 | 0.674 | 0.599 |
| + dense (e5-base) + transliteration routing | 0.888 | 0.979 | 0.735 | 0.771 |
| + EmbeddingGemma-300m — `RECOMMENDED` | **0.897** | **0.979** | **0.767** | **0.849** |

**Romanised Hindi must skip the dense leg.** Embedding models are trained on
Devanagari, not Latin transliteration, so the dense leg costs 14 points of
Hinglish recall. A query token that is an expansion-table key yet appears
nowhere in the corpus is a bridge word; those queries route to the lexical legs
and recover all of it. Partial weights still poison — it is binary.

## Generation quality

Retrieval says the answer was *available*. This says what the model did with it.

`survive_rag/generation/prompt.py` mirrors `lib/utils/prompt_builder.dart`, so
the eval scores the prompt the app actually sends.

The checks are deliberately deterministic. For safety-critical content the
question is not "is this a good answer" but "did it tell someone to apply a
tourniquet", and a string test answers that more reliably and reproducibly than
a judge model. The hard part is that a *correct* answer must say "DO NOT apply
a tourniquet", so every check is **negation-aware**: it asks whether the answer
asserts the phrase, not whether the phrase occurs.

| check | what it catches |
|---|---|
| `safety` | asserting something dangerous |
| `negation` | copying a prohibition but dropping the "DO NOT" |
| `actionable` | omitting the thing that actually helps |
| `grounded` | answering from pretraining, ignoring the guides |
| `abstention` | inventing an answer to an out-of-corpus question |

`safety` and `negation` are **critical**: failures are listed individually,
never averaged into a pass rate. One tourniquet recommendation is an incident,
not a 99% score.

## Multi-turn

12 conversations, 32 turns, covering anaphora ("should I tie something above
**it**"), topic switches, and safety-critical follow-ups. Turns flatten to
ordinary retrieval cases (`<case>#t<n>`) so the same span-resolved labels and
the same metrics apply.

A follow-up rarely stands on its own, so `survive_rag/retrieval/conversation.py`
builds the retrieval query from history three ways:

| strategy | all turns | turn 1 | follow-ups | drop |
|---|---|---|---|---|
| `bare` (what the app does now) | 59.4% | 66.7% | 55.0% | −11.7% |
| `window` | 62.5% | 66.7% | 60.0% | −6.7% |
| **`anchored`** | **68.8%** | 66.7% | **70.0%** | **+3.3%** |

`anchored` carries only the topic-bearing terms of earlier turns, so a long
conversation cannot drown the current question in its own past. It removes the
follow-up penalty entirely.

## Context window

```
2048 total − 512 reserved output − 84 safety = 1452 prompt tokens
```

| top_k | median prompt | budget used | chunks reaching the model |
|---|---|---|---|
| 3 | 1030 | 71% | 3 |
| 4 | 1259 | 87% | 4 |
| **5** | **1320** | **91%** | **5** |
| 6 | 1323 | 91% | 5 |
| 10 | 1323 | 91% | 5 |

Five is the ceiling: beyond it the budget is full and extra retrieved chunks
are dropped. `evals context` is what found the all-or-nothing bug where an
overlong block was discarded entirely, leaving the model with no context at all.

## Performance

`evals perf` reports time-to-first-token (measured with a real streamer, not
inferred), decode tokens/second, and total latency. TTFT is dominated by prompt
length — the whole prompt is processed before the first token appears — which
is why context-window discipline is a latency question and not only a quality
one. Laptop numbers are optimistic against a 4 GB Android phone; the ratios
between models are what transfers.
