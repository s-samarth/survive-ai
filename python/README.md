# survive-rag

The retrieval and generation lab for Survive AI: chunking with stable ids,
hybrid BM25 + embedding retrieval, two hand-authored golden sets, and an eval
harness that scores whole configurations against them.

**Python is the lab and the build step; Dart is the runtime.** Python cannot
ship inside the Flutter APK, so chunking runs here, offline, and emits an index
artifact the app ships and only looks up. That makes this the single source of
truth for chunk ids — which is exactly what stable citations need, because a
citation is only useful if it means the same thing in an eval report, in the
database, and in the guide reader on a phone.

The lexical path has **zero third-party dependencies**; `pytest` and `ruff`
are dev-only. The dense leg needs the `dense` extra (`numpy`, `onnxruntime`),
and the lab additionally uses `sentence-transformers` to measure candidates
before they are exported. Nothing here ships in the APK.

## The three granularities

The corpus is chunked once and read at three sizes, because three consumers
want three different things:

| view | size | who reads it |
|---|---|---|
| **child** | ~90 tokens | the citation target — what the user clicks |
| **passage** | 320 tokens, 80 overlap | what retrieval scores |
| **parent** | whole `## Part N` | what the model reads |

Scoring at citation granularity was the original mistake: a 30-token
prohibition holds too few terms for BM25 and too little meaning for an
embedding. Passages are windows of consecutive children inside one parent, so
every hit still maps back to an exact child for the citation.

## Measured configuration

| | Recall@5 | Recall@20 | MRR |
|---|---|---|---|
| child chunks, BM25 only (the original) | 0.710 | 0.866 | 0.515 |
| passage granularity, BM25 only | 0.815 | 0.950 | 0.674 |
| \+ dense leg (e5-base, RRF weight 1.5) | 0.876 | 0.950 | 0.726 |
| \+ transliteration routing | **0.888** | **0.979** | **0.735** |

`RECOMMENDED` in `config.py` is that last row.

**Romanised Hindi must skip the dense leg.** Embedding models are trained on
Devanagari, not Latin transliteration, so the dense leg costs 14 points of
Hinglish recall (60.7% → 46.4%). A query token that is an expansion-table key
yet appears nowhere in the corpus is a bridge word; those queries route to the
lexical legs and recover all of it. Partial weights still poison — it is
binary.

## Quick start

```bash
python3 -m survive_rag chunk
```

```bash
python3 -m survive_rag query "saanp ne kaat liya"
```

```bash
python3 -m survive_rag eval --sweep all --html reports/eval.html
```

```bash
python3 -m survive_rag validate
```

```bash
python3 -m survive_rag eval --sweep models --html reports/models.html
```

```bash
python3 -m survive_rag gen-eval --model qwen-1.5b --dense
```

```bash
python3 -m survive_rag chunk --export ../assets/index/corpus.json
```

## The chunking

Two levels, from one markdown guide:

| | what it is | who uses it |
|---|---|---|
| **Parent** | one `## Part N` section | the model reads it |
| **Child** | one addressable block, ~30–200 tokens | retrieval scores it, a citation points at it |

Ids are built from content, not position, so inserting a paragraph at the top
of a guide does not renumber every citation below it:

```
bites#part-3-snakebite-what-not-to-do#do-not-apply-a-tourniquet-this-is
```

Two rules override the size policy, and both exist because of what this corpus
is. **Anchors** — a bold sub-topic label, or a `DO NOT` line — always start a
new chunk, so every prohibition is separately retrievable and separately
linkable. **Bare labels** — `**Immediately:**` — are never split from the list
they introduce, because alone they say nothing.

## The golden set

`goldset/retrieval.jsonl`, 346 hand-authored cases, one JSON object per line.

```json
{"id":"bi-003","query":"should I tie a tourniquet on a snake bite",
 "gold":["bites#part-3-snakebite-what-not-to-do#do-not-apply-a-tourniquet-this-is"],
 "topic":"bites","slices":["english","prohibition"]}
```

Relevance is graded: `gold` is relevance 2, `also_relevant` is relevance 1.
Several guides legitimately cover the same emergency, and a metric that calls
the second-best chunk "wrong" punishes the retriever for being right.

Cases carry **slices**, and the slices are the point — a headline Recall@5 of
0.90 hiding a Hinglish slice at 0.55 is a failure disguised as a pass:

`english` · `hinglish` · `code_mixed` · `terse` (1–3 words) · `symptom`
(described, not named) · `misspelled` · `near_miss` (must not be confused with
a sibling) · `prohibition` · `india_specific` · `procedural` · `multi_topic` ·
`out_of_corpus` (correct behaviour is to retrieve nothing)

### Labels are resolved to source spans, not chunk ids

A label names a chunk id because that is what a human can audit. But chunk ids
are a function of the chunking policy, so a set labelled under one policy
scores zero against another — which would make the most interesting sweep
(*does chunking matter?*) impossible to run.

So each label is resolved once, against the **default** chunking, down to the
markdown lines it covers. Matching afterwards is by line overlap. Under the
default policy this reduces exactly to id equality; under any other policy the
same labels still work. `tests/test_evals.py` asserts both.

## Metrics

**Recall@5 is the headline and everything else is diagnostic.** If the chunk
that answers the question is not in what we send, no generator — however good,
however large — can produce a correct grounded answer. Every other quality
problem is recoverable; a retrieval miss is not.

| metric | why | gate |
|---|---|---|
| Recall@5 | the generator's floor | ≥ 0.90 |
| Recall@20 | ceiling on what reranking can recover | ≥ 0.97 |
| MRR | is the right chunk first, or fifth | ≥ 0.75 |
| nDCG@5 | tracks end-to-end quality; rewards ordering | ≥ 0.75 |
| Hit@1, P@5, Topic@1 | diagnostic | — |
| Abstention | out-of-corpus queries that correctly return nothing | — |

Out-of-corpus cases are excluded from the quality means and reported
separately: averaging "correctly found nothing" in with "found the right
chunk" would inflate the headline.

## Sweeps

Each sweep answers one question with an A/B, rather than moving several knobs
at once and leaving the result uninterpretable.

| sweep | question |
|---|---|
| `legs` | what does each retrieval leg contribute? |
| `rerank` | is the heuristic reranker earning its place? |
| `chunking` | does the sizing policy matter, and how much? |
| `granularity` | can a child borrow its parent's vocabulary? |
| `expansion` | where is the sweet spot for expansion breadth? |
| `headings` | how much should a heading match count? |

## Layout

```
survive_rag/
  config.py            RetrievalConfig — every field is an eval knob
  sweeps.py            named A/B sweeps
  cli.py               chunk | query | validate | eval
  corpus/
    topics.py          the 18 India situations (mirrors doc_topic.dart)
    markdown_blocks.py markdown -> line-anchored semantic blocks
    packing.py         blocks -> child-sized groups; anchor and label rules
    chunker.py         groups -> ParentChunk / ChildChunk
    slugify.py         stable, human-readable id construction
    loader.py          load the corpus; export the shipped index
  retrieval/
    tokenizer.py       normalise, stopwords, suffix stemmer
    expansion.py       synonym + Hinglish expansion
    bm25.py            Okapi BM25, pure Python
    fusion.py          reciprocal rank fusion
    rerank.py          heuristic features + MMR diversification
    pipeline.py        legs -> fusion -> rerank -> MMR -> parent expansion
  evals/
    goldset.py         load and validate the golden set
    spans.py           chunking-independent label resolution
    metrics.py         recall, MRR, nDCG, precision
    runner.py          run one or many configs
    report.py          console + gates
    report_html.py     standalone HTML report
```

## Parity with the Dart side

Three things must not drift, and each has a test that fails when it does:

- topic keys, against `lib/models/doc_topic.dart`
- the expansion vocabulary, against `lib/utils/expansion_terms.dart`
- parent section size, against the 1452-token prompt budget in
  `lib/services/llm_service.dart`

## Dev

```bash
python3 -m venv .venv && .venv/bin/pip install pytest ruff
```

```bash
.venv/bin/python -m pytest tests -q && .venv/bin/ruff check survive_rag tests --line-length 100
```


## The generation eval

Retrieval tells you the answer was *available*. This tells you what the model
did with it.

`prompt.py` mirrors `lib/utils/prompt_builder.dart` exactly — instruction
last, 700-character chunk cap, `words x 1.3` estimate, 1452-token budget — so
the eval scores the prompt the app actually sends.

The checks are deliberately deterministic. For safety-critical content the
question is not "is this a good answer" but "did it tell someone to apply a
tourniquet", and a string test answers that more reliably and reproducibly
than a judge model. The hard part is that a *correct* answer must say "DO NOT
apply a tourniquet", so every check is **negation-aware**: it asks whether the
answer asserts the phrase, not whether the phrase occurs. Polarity is modelled
in two parts — prefix cues that negate what follows (`never`), and clause cues
that are predicates about the phrase (`is harmful`).

| check | what it catches |
|---|---|
| `safety` | asserting something dangerous |
| `negation` | copying a prohibition but dropping the "DO NOT" |
| `actionable` | omitting the thing that actually helps |
| `grounded` | answering from pretraining, ignoring the guides |
| `abstention` | inventing an answer to an out-of-corpus question |

`safety` and `negation` are **critical**: failures are counted and listed
individually, never averaged into a pass rate. One tourniquet recommendation
is an incident, not a 99% score.

Generators are pluggable, so a model bake-off is a config change. The shipped
model (`gemma-2b`) is gated on Hugging Face and needs `huggingface-cli login`
with the licence accepted; the open Qwen and SmolLM entries need nothing.

## Model bake-off

Run `eval --sweep models`. Measured at passage granularity, RRF weight 1.5:

| model | params | Recall@5 | Hinglish |
|---|---|---|---|
| lexical only | 0 | 0.815 | 60.7% |
| minilm | 22M | 0.844 | 28.6% |
| bge-small | 33M | 0.856 | 39.3% |
| e5-small | 118M | 0.856 | 39.3% |
| e5-base | 278M | **0.876** | 46.4% |

Document vectors are computed here and shipped inside the index artifact, so a
device only ever embeds the query — one forward pass over ~10 tokens. 201
passages at 768 dims is 636 KB; at 256 dims via Matryoshka truncation, 212 KB.

`embedder_onnx.py` runs the same models under `onnxruntime`, which is what the
app would carry. `tests/test_embedder.py` asserts the two backends agree; run
it with `SURVIVE_RAG_NETWORK_TESTS=1`.
