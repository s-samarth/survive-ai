# Golden set

`retrieval.jsonl` — 382 hand-authored cases, one JSON object per line. JSONL so
a diff shows one changed case per line and cases can be appended without
rewriting the file. Blank lines and `#` comments are skipped, so the file can
be annotated in place.

## Fields

| field | required | meaning |
|---|---|---|
| `id` | yes | stable short id, `<topic-prefix>-<nnn>` |
| `query` | yes | exactly what a user would type, misspellings included |
| `gold` | — | chunk ids that answer the query (relevance 2). Empty means the query is out of corpus and the retriever should find nothing |
| `also_relevant` | — | useful but not the best answer (relevance 1) |
| `topic` | — | expected guide, scored as Topic@1 |
| `slices` | — | tags this case is reported under |
| `note` | — | why a non-obvious label is what it is |

## Adding cases

1. Find the chunk id: `python3 -m survive_rag query "<your query>"`.
2. Append the case.
3. `python3 -m survive_rag validate` — this fails on unknown ids, duplicate
   case ids, and empty `gold` that is not tagged `out_of_corpus`.

Never invent an id by hand. Ids are content-derived, so a plausible-looking
guess will not exist and the label will be silently useless until `validate`
catches it.

## When a guide is edited

Editing a guide can rename the chunks in the section you touched. `validate`
fails loudly rather than letting the score quietly drop. Re-run
`python3 -m survive_rag query` on the affected cases and update the ids.

## What the set deliberately contains

Well-formed English questions are the easy case and prove very little. The set
is weighted toward what actually arrives: terse two-word queries, romanised
Hindi, symptoms described rather than named, sibling conditions that must not
be confused, users asking permission to do the forbidden thing, misspellings,
and out-of-corpus queries the retriever should find *nothing* for.

Slice-by-slice breakdown, the reasoning behind each, and how the generation and
multi-turn sets are built: **[docs/GOLDEN_SETS.md](../../../docs/GOLDEN_SETS.md)**.
