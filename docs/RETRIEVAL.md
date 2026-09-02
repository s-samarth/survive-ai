# Retrieval — Design, and Why It Works

How a question becomes four paragraphs of guide text in the model's prompt.
Every number here is measured; see [RESULTS.md](RESULTS.md) for the runs and
[EVALUATION.md](EVALUATION.md) for how to reproduce them.

---

## The shape of the problem

The corpus is 18 India-specific survival guides — roughly 160 `## Part N`
sections, 516 paragraphs, 201 retrieval passages. It is small, structured, and
never changes at runtime.

The queries are not. Real input in an emergency is terse ("chest pain"),
misspelled, romanised Hindi ("saanp ne kaat liya"), or phrased in words the
guides never use ("my friend is bleeding a lot" against a guide that says
"haemorrhage"). Two-thirds of the difficulty is vocabulary, not ranking.

That asymmetry — a fixed tiny corpus against wildly variable queries — is what
makes the design work. Everything expensive can be precomputed; only the query
has to be handled live.

---

## Three granularities over one chunk tree

The corpus is chunked once, offline, and read at three sizes because three
consumers want three different things.

| view | size | who reads it |
|---|---|---|
| **child** | ~90 tokens | the citation target — what the user taps |
| **passage** | 320 target, 480 max, 80 overlap | what retrieval scores |
| **parent** | whole `## Part N` | what the model reads |

Passages are sliding windows over consecutive children, and a window never
straddles a parent. So every passage hit still resolves to an exact child for
the citation, and the model still receives whole coherent sections.

**Scoring at citation granularity was the original mistake.** A 30-token
prohibition — "Do not cut the bite" — holds too few terms for BM25 to rank and
too little context for an embedding to place. Moving scoring to passages while
keeping citations at child granularity was worth **+10.5 points of Recall@5**
(0.710 → 0.815) before any embedding model was involved.

---

## Three legs, fused by RRF

```
query
  ├── leg 1  BM25, literal          weight 1.0
  ├── leg 2  BM25, query-expanded   weight 0.7
  └── leg 3  dense cosine           weight 1.5   (skipped for romanised Hindi)
                    │
              Reciprocal Rank Fusion, K = 60
                    │
              top 5 passages → prompt
```

### Why RRF and not score normalisation

BM25 scores live in roughly `[0, 30]` and depend on corpus statistics; cosine
lives in `[0, 1]`. There is no principled way to put them on one scale without
per-corpus tuning that would need re-tuning every time a guide is edited. RRF
throws away magnitudes and keeps only ranks:

```
score(d) = Σ_i  weight_i / (K + rank_i(d))
```

`K = 60` damps the very top positions, so a passage ranked 3rd by two legs
beats one ranked 1st by a single leg. Empty legs contribute nothing, so the
pipeline degrades cleanly to whatever signals exist — which is exactly what
happens on a device that has not downloaded the query encoder.

### The weights are measured, not chosen

`literal 1.0, expanded 0.7, dense 1.5` come from sweeps over the golden set.
They live in `RetrievalConfig` (Python) and `RagService` (Dart) and **must stay
in sync**; changing one in Dart without rerunning `python -m evals eval --dense`
puts the device somewhere the lab has never scored. There is a test that
catches divergence — see [TESTING.md](TESTING.md).

---

## Leg 1 and 2: BM25, twice

**Literal** runs the user's words. **Expanded** runs them plus synonyms from
`QueryExpander`, capped at 10 additions to avoid diluting the query.

The expansion vocabulary is the India-specific part of the system and carries
three kinds of entry:

- **Domain synonyms** — bleeding → haemorrhage, wound, tourniquet
- **Romanised Hindi** — khoon → blood, aag → fire, saanp → snake, baadh → flood
- **India-specific nouns** — LPG, lathi, nala, ORS, ASV

Without the Hinglish entries a large share of real Indian queries retrieve
nothing at all. This is not a nice-to-have.

### FTS5's implicit operator is AND

On the device, BM25 is SQLite FTS5's `bm25()` over an external-content virtual
table. FTS5 ANDs bare terms, so passing a raw sentence to `MATCH` demands that
every word — including "how", "I", "from" — appear in one passage, and returns
nothing for virtually any real question.

`DatabaseService.buildMatchExpression` strips stopwords, quotes each term (so
that a query containing "or" or "near" is not parsed as syntax), and OR-joins
them. Every query goes through it. There is a regression test; do not bypass it.

Field weights are `topic 1.0, heading_path 2.0, body 1.5` — a heading match is
strong evidence of topical fit in a corpus this structured.

---

## Leg 3: dense retrieval

EmbeddingGemma-300m, quantised to `q4f16` and exported to ONNX.

**The corpus is embedded offline and ships as vectors.** The device only ever
embeds the query — one forward pass over ~10 tokens, not 201 over paragraphs.
That asymmetry is the whole reason a 300M-parameter encoder fits beside a 2B
generator. Full detail in
[ON_DEVICE_EMBEDDINGS.md](ON_DEVICE_EMBEDDINGS.md).

Similarity is brute-force cosine over ~201 passages. At 768 dimensions that is
sub-millisecond on ARM; an approximate nearest-neighbour index would be pure
complexity at this size.

### Romanised Hindi must skip the dense leg

This overturned the expectation going in. On the Hinglish slice:

| | Recall@5 |
|---|---|
| lexical legs only | **60.7%** |
| every embedding model tried | 28–46% |

Embedding models are trained on Devanagari, not Latin transliteration; they
rate "saanp" barely above noise. Routing transliterated queries to the lexical
legs recovers all 14 points, costs nothing on English, and lifted Recall@20 to
0.98.

**The routing is binary.** Partial weights still poison the ranking — a leg
that is confidently wrong pollutes the fusion even at reduced weight.

### How a query is detected as transliterated

From an **explicit list** (`kTransliteratedTerms` / `transliteration.py`), not
inferred.

Inferring it as "an expansion key that never appears in the corpus" looked
elegant and was silently wrong: the guides mention `aag` once, so a query of
"aag" — *fire* — was not recognised as Hinglish and came within 0.003 of being
declined outright. An explicit list cannot be invalidated by a guide edit.

---

## Citations

The retrieved passage is what the model reads; the **citation** is the child
paragraph the user taps to verify. Choosing which child to cite is its own
ranking problem.

Three lexical strategies all sat at 0.650–0.654 citation recall. Flattening the
retrieved passages back to their children and ranking those *densely* reaches
**0.849** — worth 20 points over lexical selection, using vectors that are
already loaded.

Chunk ids are content-derived and assigned offline, so a citation means the
same thing in an eval report, in the database, and in the guide reader on a
phone. That is the entire reason chunking moved out of the app.

---

## What reaches the prompt

Top 5 passages, each capped at 1400 characters, filled greedily into a
1452-token budget until the next one does not fit.

**Five is the measured ceiling**, not a round number: at the 1400-character cap
five passages fill 91% of the budget, and a sixth is simply dropped. The cap
itself was 700 characters when a chunk was one ~90-token paragraph; against
320-token passages that truncated 91% of them while 39% of the budget sat
unused.

The fill is greedy and always keeps at least one passage. The previous
all-or-nothing form failed silently and catastrophically: when the block did not
fit, the model received **no** reference material and answered from pretraining
— the exact failure retrieval exists to prevent, and invisible to any metric
that does not inspect the prompt.

---

## What was deliberately not built

**A reranker.** Cross-encoders are the obvious next step and the smallest
useful ones are 100 MB+ of extra resident model, plus a second forward pass on
the latency-critical path. Recall@20 is 98%, so the headroom a reranker would
exploit is 8 points of ordering inside an already-good candidate set — the
wrong 100 MB to spend when the generator is the weaker link.

**Approximate nearest neighbours.** 201 vectors.

**Score normalisation.** See RRF above.

**On-device chunking.** Chunk ids have to be stable across the app, the eval
harness and the guide reader. A Dart implementation no eval could see is how
citations drift.

---

## Related

- [ON_DEVICE_EMBEDDINGS.md](ON_DEVICE_EMBEDDINGS.md) — the dense leg on a phone
- [RESULTS.md](RESULTS.md) — every measured number
- [EVALUATION.md](EVALUATION.md) — the harness
- [GOLDEN_SETS.md](GOLDEN_SETS.md) — how the labels were built
