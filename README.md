# Survive AI

> An offline-first survival assistant that runs a 2B language model and a
> retrieval pipeline entirely on an Android phone. Scoped to India. No network
> at runtime.

---

## The Problem

Emergencies take the network with them. Floods and cyclones drop cell towers;
blackouts and internet shutdowns remove the rest. The moments when someone most
needs to know what to do — a snakebite, a crowd crush, a gas leak, severe
bleeding — are the moments they cannot look it up.

The knowledge exists. It is written down, in NDMA advisories and clinical
guidance. It is just not reachable from a phone with no bars.

---

## What It Does

- **Answers questions offline.** *"kutte ne kaata"*, *"chest pain"*, *"baadh aa
  gayi hai kya karu"* — English, romanised Hindi, or two panicked words.
- **Grounds every answer in the guides**, retrieves the passages first, and
  cites the paragraph the answer came from.
- **Declines what it does not cover**, rather than guessing. Ask what it can do
  and it tells you.
- **Checks its own output** against the reference material it was given, and
  blocks an answer that asserts something the guides forbid.
- **Updates content and model over WiFi** from a manifest, without an APK
  release.

18 guides, scoped to India: floods, cyclones, earthquakes, landslides,
blackouts and internet shutdowns, civil unrest, blasts, war, crowd crush,
chemical and gas, fire, snake and animal bites, heat and cold, water and food,
shelter, medical, vulnerable groups, first response.

The India scope is a design decision, not a limitation to be fixed later. The
corpus, the emergency numbers (112), the query-expansion vocabulary including
romanised Hindi, and the topic taxonomy are all India-specific.

---

## Design Philosophy: Speed Over Sophistication

In a survival emergency, you don't need the most sophisticated AI — you need the fastest correct answer. Every architectural decision in Survive AI optimizes for this principle:

**Why a 2B model, not a larger one?**
Gemma 2B IT reaches its first token far sooner than a 7B, which does not fit
alongside the retrieval stack at all. Measured time to first token is currently
6.1 s on a laptop against a target of 3 s — the gap is prefill over ~1300
prompt tokens, and it is the main open performance problem.

**Why hybrid retrieval, and why the corpus is embedded offline?**
Keyword search alone reaches Recall@5 of 81.5%; adding a dense leg takes it to
89.7%. That leg is affordable only because the corpus never changes: all 201
passage vectors are computed at build time and ship as a 603 KB file, so the
phone embeds the *query* and nothing else — one forward pass over ~10 tokens.
Sizing an encoder against "embed the corpus at launch" and against "embed ten
tokens per turn" give completely different answers.

**Why a simple prompt structure, not a complex agent?**
A 2B model has limited instruction-following capacity. Complex multi-step prompts with lengthy system instructions get "forgotten" by the time the model starts generating. We place a short, focused instruction (~60 tokens) right before the question — where the model's attention is strongest — and put reference material earlier in the prompt. This is prompt engineering optimized for small models, not large ones.

**Why offline-first, not cloud-with-fallback?**
Because "fallback" implies the network might work. In a conflict zone, it won't. The entire app must function as if the network will never come back after setup. This constraint drives every decision — from bundling survival guides as Flutter assets (available before any sync) to using SQLite instead of a cloud database.

---

## Technical Architecture

### The Edge AI Stack

```
┌─────────────────────────────────────────────────────────┐
│          SURVIVE AI — 6 GB ANDROID DEVICE (min)          │
│                                                          │
│  UI Layer (Flutter / Riverpod)                           │
│  ┌─────────────┐  ┌───────────────┐  ┌──────────────┐  │
│  │ LlmService  │  │  RagService   │  │ SyncService  │  │
│  │ Gemma 2B IT │  │ BM25 + Query  │  │ WiFi-gated   │  │
│  │ CPU backend │  │ Expansion+RRF │  │              │  │
│  └──────┬──────┘  └───────┬───────┘  └──────┬───────┘  │
│         │                 │                  │          │
│         │          DatabaseService (SQLite)              │
│         │     (docs, chunks, chunks_fts via FTS5)       │
│         │                                                │
│  gemma-2b-it-cpu-int4.bin  (~500MB, INT4 quantized)     │
│  /docs/{topic}/*.md        (~20MB survival guides)      │
│  survive_ai.db             (~10MB indexed chunks)       │
└─────────────────────┬────────────────────────────────────┘
                      │ WiFi only (one-time setup + sync)
               GitHub: survive-ai-docs
```

### Memory Budget

**Minimum 6 GB RAM, 8 GB recommended.** Budgeted, not yet measured on hardware.

| Component | RAM |
|---|---|
| Android OS + system services | ~1.8 GB |
| Gemma 2B IT (INT4, CPU, mmap'd) | ~1.6 GB |
| KV cache (2048-token context) | ~150 MB |
| Flutter framework + app heap | ~200 MB |
| EmbeddingGemma q4f16 (mmap'd, reclaimable) | ~175 MB |
| Packed tokenizer tables | ~18 MB |
| SQLite + FTS5 index | ~20 MB |
| Passage vectors | 0.6 MB |

The encoder's weights sit in a sidecar file that ONNX Runtime memory-maps, so
those pages are file-backed and the OS can evict them when Gemma needs the RAM.
That is what makes a second model viable at all — and why the encoder is
optional: without it the app answers on its two lexical legs.

Other consequences of the budget:
- The LLM runs on the **CPU backend**. GPU inference draws from the same shared
  pool and the OS cannot reclaim it under pressure; CPU uses pageable RAM.
- The **KV cache is recycled** between turns — the old session is closed before
  the new one allocates, so RAM stays flat regardless of conversation length.
- Streaming UI updates are **batched at 50 ms** to reduce GC pressure.

### RAG Pipeline: Simple, Fast, Grounded

```
User: "I'm bleeding badly from my leg"
  │
  ├─ Leg 1: BM25 exact ──────── FTS5 MATCH "bleeding badly leg"
  │                               → chunks about bleeding, wounds
  │
  ├─ Leg 2: BM25 expanded ───── QueryExpander maps "bleeding" →
  │                               "hemorrhage wound tourniquet pressure"
  │                               FTS5 MATCH expanded query
  │                               → chunks about tourniquet, hemorrhage control
  │
  └─ Leg 3: Dense cosine ────── EmbeddingGemma-300m encodes the query;
  │                               passage vectors shipped precomputed
  │                               (skipped for romanised Hindi — see below)
  │
  ▼
  3-way Reciprocal Rank Fusion (RRF, K=60), weights 1.0 / 0.7 / 1.5
  score(chunk) = Σ weight_i / (rank_in_list + 60)
  │
  ▼
  Top 5 passages selected → prompt → Gemma generates → output guarded
  │
  ▼
  "Apply firm, direct pressure to the wound immediately using
   the cleanest cloth available. Do NOT remove it..."
```

**Query expansion and the dense leg solve different halves of the same problem.**
A user in panic says "I'm bleeding"; the guides say "haemorrhage control". BM25
alone misses that — the words do not overlap. Expansion bridges it with a
hand-built survival dictionary that also carries romanised Hindi (*khoon* →
blood, *aag* → fire, *saanp* → snake) and India-specific nouns (LPG, lathi,
nala, ORS, ASV). It is a pure Dart string operation: no memory, sub-millisecond.

The dense leg catches what no dictionary anticipates — paraphrase, and symptoms
described rather than named ("hot dry skin, confused, not sweating" → heat
stroke).

**Romanised Hindi skips the dense leg entirely.** Embedding models are trained
on Devanagari and rate "saanp" barely above noise: the lexical legs alone score
60.7% on the Hinglish slice against 28–46% for every dense model tried. Routing
those queries to the lexical legs recovers all 14 points. Partial weights still
poison the ranking, so the routing is binary.

Full detail in [docs/RETRIEVAL.md](docs/RETRIEVAL.md).

### Prompt Engineering for 2B Models

Standard LLM prompt engineering assumes a model with strong instruction-following (GPT-4, Claude, Gemma 27B). A 2B model is fundamentally different — it has limited attention span and tends to "forget" instructions that appear early in the context.

**The problem we solved:** A 260-token system prompt at the top of the context was being ignored by Gemma 2B by the time it reached the question. The model would generate fictional scenarios, repeat context verbatim, or produce prompt-like text instead of answers.

**Our solution — instruction-last prompt structure:**

```
[Reference material from survival guides]        ← farthest from generation
[medical > Tourniquet Application]
Apply a tourniquet 2-3 inches above the wound...

[Previous exchange]                               ← middle
Q: How do I stop the bleeding?
A: Apply direct pressure with a clean cloth...

You are Survive AI, an offline survival expert.   ← RIGHT BEFORE generation
Answer the question below directly and helpfully.
Give the most critical action FIRST...

Question: The bleeding won't stop, what now?      ← last token before model generates
```

This structure places the instruction (~60 tokens) immediately before the question, where the 2B model's attention is strongest. Reference material goes first because it's "data" the model references, not "instructions" it must follow.

**Additional prompt optimizations:**
- Trivial queries (< 3 words like "hi") skip RAG retrieval entirely — injecting irrelevant survival chunks for greetings confuses the small model
- History uses Q:/A: format instead of User:/Assistant: — avoids role confusion inside a single turn block
- History fills **newest-first**, max 4 turns; questions capped at 400 chars, answers at 220. A question is short and load-bearing; an answer is long and the model can restate it. Filling oldest-first kept the oldest turns and dropped the newest — exactly backwards for a follow-up
- A follow-up's retrieval query is **anchored** on topic-bearing terms from earlier turns, which removes the follow-up recall penalty entirely (+3.3% against −11.7% for the bare query)
- Token budget of 1452 (2048 context − 512 output − 84 safety): instruction and question reserved first, a history reserve held back, reference passages filling the rest greedily and always keeping at least one

### Memory Safety: Why the App Doesn't Crash

On-device inference on a 6 GB phone leaves little slack. The specific
protections:

| Risk | Protection |
|---|---|
| GPU + app competing for shared memory | CPU backend only — Gemma uses pageable RAM that Android can manage |
| KV cache accumulation across turns | Session recycled every turn — old session nulled and closed BEFORE new one allocates |
| Rapid UI updates causing GC storms | Token streaming batched at 50ms intervals (~20 updates/response instead of ~512) |
| Prompt exceeding context window | Greedy fill inside a 1452-token budget, always keeping at least one passage. The previous all-or-nothing form dropped **all** reference material when the block did not fit, and the model answered from pretraining |
| Second ML runtime competing for RAM | Corpus embedded offline; the encoder's weights are memory-mapped and file-backed, so the OS can reclaim them |
| Inference errors crashing the app | Stream errors caught via `.handleError()` and surfaced as UI messages |
| flutter_gemma double-wrapping turn markers | Prompt returned as plain text — flutter_gemma adds `<start_of_turn>` markers automatically |

---

## Technology Stack

| Component | Choice | Why |
|---|---|---|
| Framework | Flutter (Dart) | Cross-platform, Material 3, single codebase |
| On-device LLM | Gemma 2B IT (INT4, ~500MB) | Smallest capable model; CPU backend; 6 GB device floor |
| LLM Runtime | flutter_gemma (MediaPipe) | Google's official on-device inference; streaming output |
| RAG Retrieval | SQLite FTS5 (BM25) | Built into sqflite; zero extra dependencies; sub-50ms |
| Vocabulary bridge | Query expansion (pure Dart) | Survival synonyms, romanised Hindi, India-specific nouns; zero memory |
| Dense retrieval | EmbeddingGemma-300m, ONNX q4f16 | Query encoded on device; corpus vectors precomputed and shipped |
| Retrieval merge | Weighted RRF (K=60) | Merges three legs without score normalisation; degrades cleanly |
| Index build | Python (`python/survive_rag`) | Chunking and embedding run offline so chunk ids — and citations — are stable everywhere |
| State management | Riverpod 2.x | Constructor-injectable, testable |
| Docs hosting | GitHub public repo | Free, community PR workflow |
| Distribution | Direct APK sideload | Works via USB in regions with restricted internet |

---

## Code Navigation

```
lib/
├── main.dart                          entry + _EntryRouter; seeds the corpus every launch
│
├── models/
│   ├── chat_message.dart              role, content, timestamp
│   ├── citation.dart                  paragraph-level source with line spans
│   ├── doc_chunk.dart                 passage + its shipped embedding
│   ├── doc_manifest.dart              manifest schema: model, encoder, docs
│   └── doc_topic.dart                 the 18 India situations — single source of truth
│
├── services/
│   ├── chat_turn_service.dart         one turn: route → anchor → retrieve → prompt → generate → guard
│   ├── llm_service.dart               the ONLY flutter_gemma caller
│   ├── rag_service.dart               3-leg weighted RRF; dense confidence for routing
│   ├── database_service.dart          SQLite schema, FTS5, all CRUD
│   ├── database_citations.dart        citations table extension
│   ├── index_loader_service.dart      reads the offline-built index + vectors
│   ├── chunker_service.dart           fallback chunker for docs synced after the build
│   ├── sync_service.dart              WiFi-gated GitHub sync; seedFromAssets()
│   ├── download_service.dart          resumable downloads + SHA-256
│   ├── embedding_service.dart         base (disabled) embedder
│   └── embedding/
│       ├── embedder_bootstrap.dart    assembles the encoder from its three artifacts
│       ├── gemma_tokenizer.dart       BPE port; reads the packed tokenizer
│       ├── onnx_embedder.dart         EmbeddingGemma under ONNX Runtime
│       ├── vector_index.dart          shipped passage vectors + manifest check
│       └── encoder_download.dart      fetches the graph and its weight sidecar
│
├── utils/
│   ├── prompt_builder.dart            instruction-last template; greedy context fill
│   ├── prompt_history.dart            newest-first history within its reserve
│   ├── query_router.dart              capability / answer / decline, before a model runs
│   ├── answer_guard.dart              BLOCK an assertion, AUGMENT an omission
│   ├── app_responses.dart             capability answer, refusal, warning footer
│   ├── conversation.dart              follow-up anchoring for retrieval
│   ├── query_expander.dart            synonym + Hinglish expansion
│   ├── expansion_terms.dart           the expansion vocabulary
│   └── transliteration.dart           explicit romanised-Hindi list
│
├── providers/providers.dart           Riverpod wiring, singleton lifecycle
├── screens/                           one file per full-page route
└── widgets/                           MessageBubble, ChatEmptyState, RetrievalStatus,
                                       ChatInputBar, EncoderDownloadTile, SyncStatusBanner

python/
├── survive_rag/                       reference implementation + build step (ships nothing)
└── evals/                             golden sets, metrics, harnesses (never ships)
```

---

## Key Flows

### First Launch
`DisclaimerScreen` → acknowledge → `_EntryRouter` checks for the model →
`SetupScreen` fetches `manifest.json` → downloads Gemma 2B IT (~500 MB,
resumable, SHA-256 verified) → model loaded → `HomeScreen`. The corpus is
seeded from bundled assets on **every** launch, independent of the model, so a
sideloaded build is never left with an empty index. The query encoder is a
separate, optional download offered in Settings.

### Every Chat Turn
User message → `QueryRouter` decides capability / answer / decline → follow-up
anchoring → 3-leg retrieval → weighted RRF → top 5 passages fitted into the
token budget → instruction-last prompt → Gemma streams tokens (50 ms batched) →
`AnswerGuard` checks the output against its own reference material

### Doc Sync
App opens with WiFi → `SyncService.checkForUpdates()` → compares manifest
version → downloads only docs whose SHA-256 changed → re-chunks and re-indexes
in SQLite, embedding anything the shipped vector file does not cover

---

## Distribution

Survive AI is distributed as a direct APK — no Play Store required. This is intentional: it allows the app to spread via USB sticks, local mesh networks, and peer-to-peer sharing in environments where app stores are inaccessible.

See [docs/INSTALLATION.md](docs/INSTALLATION.md) for sideloading instructions.

---

## Documentation

**How it works**

| Document | What it covers |
|---|---|
| [SYSTEM_DESIGN.md](docs/SYSTEM_DESIGN.md) | Architecture, prompt engineering, memory safety, schema |
| [RETRIEVAL.md](docs/RETRIEVAL.md) | Chunking, the three legs, fusion, citations — and why each works |
| [ON_DEVICE_EMBEDDINGS.md](docs/ON_DEVICE_EMBEDDINGS.md) | Running a 300M encoder on a phone; the artifacts; the traps |

**How we know it works**

| Document | What it covers |
|---|---|
| [RESULTS.md](docs/RESULTS.md) | Every measured number, and what each run configured |
| [EVALUATION.md](docs/EVALUATION.md) | The harness: four measurements, metrics, release gates |
| [GOLDEN_SETS.md](docs/GOLDEN_SETS.md) | How the three label sets were built and why they are shaped that way |
| [TESTING.md](docs/TESTING.md) | Device parity strategy, and what is still unverified |

**Working on it**

| Document | What it covers |
|---|---|
| [DEVELOPER_GUIDELINES.md](docs/DEVELOPER_GUIDELINES.md) | Conventions, testing, adding docs/topics/models |
| [INSTALLATION.md](docs/INSTALLATION.md) | Installing, sideloading, deploying |
| [USER_FLOWS.md](docs/USER_FLOWS.md) | User flows |
| [FUTURE_ROADMAP.md](docs/FUTURE_ROADMAP.md) | What is planned, and what will deliberately not be built |
| [PRODUCT_OVERVIEW.md](docs/PRODUCT_OVERVIEW.md) | Non-technical summary |
| [python/README.md](python/README.md) | The lab and the build step |

---

## Contributing

Survive AI welcomes contributions from developers, survival experts, medics, translators, and field workers.

- **App code** — open a PR to this repo. Follow the [Developer Guidelines](docs/DEVELOPER_GUIDELINES.md).
- **Survival docs** — contribute to the [survive-ai-docs](https://github.com/survive-ai/survive-ai-docs) repo. Medical content requires SME review.

**What we will not build:** real-time communication, location tracking, telemetry, paid features, AI-generated medication prescriptions, or political content.

---

## License

Open-source. Humanitarian mission. Free forever.

**Maintainer:** [@samarthsaraswat](https://github.com/samarthsaraswat)
**Bug reports:** [github.com/survive-ai/survive-ai/issues](https://github.com/survive-ai/survive-ai/issues)
**Security vulnerabilities:** email directly — do not open a public issue.
