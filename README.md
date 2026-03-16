# Survive AI

> An offline-first AI survival assistant that runs entirely on a 4GB Android phone. No internet. No cloud. No excuses. Just life-saving guidance when every second counts.

---

## The Problem

Every year, millions of people find themselves in life-threatening situations with no internet access and no trained responders nearby — civilians in conflict zones in Ukraine, Gaza, Sudan, and Iran; aid workers in remote areas; journalists in hostile environments; hikers stranded in the wilderness.

In these moments, people need clear, expert guidance. But they can't Google it. They can't call an expert. Their connection is gone.

**There is no reliable, offline-capable AI assistant built for survival. Until now.**

---

## Why This Matters

Cloud AI is useless when the infrastructure is destroyed. ChatGPT requires a server. Google requires a cell tower. When bombs are falling or you're bleeding in the wilderness, you have your phone, nothing else.

Survive AI is the first app that puts a complete AI survival expert — backed by curated, expert-reviewed knowledge — inside a device that fits in your pocket and works with zero connectivity. Download once over WiFi. Works forever after.

This isn't a toy demo of on-device AI. This is AI deployed where it matters most: at the edge of human survival.

---

## Why Now

Three things converged in 2026 to make this possible:

1. **Geopolitical instability at a 30-year high.** Active conflicts affect tens of millions of civilians who need survival knowledge but lack reliable internet.
2. **Smartphone penetration in conflict regions is high.** 60–80% of people in affected areas carry Android smartphones — the hardware is already in their hands.
3. **On-device AI is finally capable enough.** Gemma 2B runs on a mid-range Android with 4GB RAM. A ~500MB download is all it takes. This wasn't possible even 12 months ago.

---

## What Survive AI Does

- **Ask anything** — "How do I treat a deep wound?" "How do I find water in the jungle?" "What do I do if bombs are falling near my home?"
- **RAG-grounded answers** — Every response is grounded in expert-written survival docs retrieved in real-time. The AI doesn't hallucinate procedures — it cites what it knows from curated guides.
- **Browse survival docs** — Read expert-written guides organized by topic: War, Medical, Jungle, Desert, Urban, General.
- **Silent sync** — When WiFi is available, the app silently checks for updated survival docs and downloads only what changed.

All computation runs locally. No account. No subscription. No tracking. No cloud.

---

## Design Philosophy: Speed Over Sophistication

In a survival emergency, you don't need the most sophisticated AI — you need the fastest correct answer. Every architectural decision in Survive AI optimizes for this principle:

**Why a 2B model, not a larger one?**
Gemma 2B IT generates its first token in under 3 seconds on a mid-range phone. A 7B model takes 10+ seconds and crashes on 4GB devices. When someone is bleeding, 7 seconds is the difference between applying pressure and passing out.

**Why BM25 keyword search, not vector embeddings?**
BM25 via SQLite FTS5 retrieves 4 relevant chunks in under 50ms with zero additional memory. A vector embedding model (even a small one) adds 200+ MB of RAM alongside the LLM — enough to trigger Android's OOM killer on a 4GB device. We bridge the vocabulary gap with domain-specific query expansion (pure Dart, zero memory cost) instead of neural embeddings.

**Why a simple prompt structure, not a complex agent?**
A 2B model has limited instruction-following capacity. Complex multi-step prompts with lengthy system instructions get "forgotten" by the time the model starts generating. We place a short, focused instruction (~60 tokens) right before the question — where the model's attention is strongest — and put reference material earlier in the prompt. This is prompt engineering optimized for small models, not large ones.

**Why offline-first, not cloud-with-fallback?**
Because "fallback" implies the network might work. In a conflict zone, it won't. The entire app must function as if the network will never come back after setup. This constraint drives every decision — from bundling survival guides as Flutter assets (available before any sync) to using SQLite instead of a cloud database.

---

## Technical Architecture

### The Edge AI Stack

```
┌─────────────────────────────────────────────────────────┐
│               SURVIVE AI — 4GB ANDROID DEVICE            │
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

### Memory Budget (Why Every Byte Matters)

On a 4GB Android device, the memory budget is brutally tight:

| Component | RAM Usage |
|---|---|
| Android OS + system services | ~1.5 GB |
| Flutter framework + app heap | ~200 MB |
| Gemma 2B IT (INT4, CPU backend) | ~1.6 GB |
| SQLite + FTS5 index | ~30 MB |
| KV cache (per inference turn) | ~200 MB |
| **Total** | **~3.5 GB** |
| **Remaining headroom** | **~500 MB** |

With only 500MB of headroom, there is no room for a second ML model (embedding model, classifier, etc.). This is why:
- Query expansion uses a pure Dart dictionary (zero memory cost) instead of a neural embedding model
- The LLM runs on CPU backend (pageable RAM) instead of GPU (shared memory pool that Android cannot reclaim)
- KV cache is recycled between turns (old session closed before new one allocates)
- UI updates are batched at 50ms intervals to reduce GC pressure

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
  └─ Leg 3: Dense (future) ──── Currently stubbed, infrastructure ready
  │
  ▼
  3-way Reciprocal Rank Fusion (RRF, K=60)
  score(chunk) = Σ 1/(rank_in_list + 60)
  │
  ▼
  Top 4 chunks selected → injected into prompt → Gemma generates
  │
  ▼
  "Apply firm, direct pressure to the wound immediately using
   the cleanest cloth available. Do NOT remove it..."
```

**Why query expansion instead of neural embeddings?**
A user in panic says "I'm bleeding." The survival docs say "hemorrhage control" and "tourniquet application." BM25 alone misses this — the words don't overlap. Neural embeddings would catch the semantic similarity, but require ~200MB of additional RAM that we don't have.

Query expansion bridges this gap with a hand-crafted dictionary of 130+ survival-domain synonym mappings. `"bleeding"` expands to `"hemorrhage wound blood tourniquet pressure dressing bandage"`. This runs as a pure Dart string operation — zero memory, sub-millisecond, and specifically tuned for survival terminology. The expanded query runs as a second BM25 search leg, and Reciprocal Rank Fusion merges both results.

The architecture supports adding dense embeddings as a third leg when device capabilities improve — the 3-way RRF infrastructure is already built and tested.

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
- Individual messages capped at 400 chars, max 4 turns of history — prevents history from consuming the context window
- Token budget system (3500 max) with priority-based allocation: instruction + question reserved first, then context, then history

### Memory Safety: Why the App Doesn't Crash

On-device LLM inference on a 4GB phone is a memory minefield. Here are the specific protections:

| Risk | Protection |
|---|---|
| GPU + app competing for shared memory | CPU backend only — Gemma uses pageable RAM that Android can manage |
| KV cache accumulation across turns | Session recycled every turn — old session nulled and closed BEFORE new one allocates |
| Rapid UI updates causing GC storms | Token streaming batched at 50ms intervals (~20 updates/response instead of ~512) |
| Prompt exceeding context window | Token budget system caps prompt at 3500 tokens with priority-based truncation |
| Inference errors crashing the app | Stream errors caught via `.handleError()` and surfaced as UI messages |
| flutter_gemma double-wrapping turn markers | Prompt returned as plain text — flutter_gemma adds `<start_of_turn>` markers automatically |

---

## Technology Stack

| Component | Choice | Why |
|---|---|---|
| Framework | Flutter (Dart) | Cross-platform, Material 3, single codebase |
| On-device LLM | Gemma 2B IT (INT4, ~500MB) | Smallest capable model; runs on 4GB devices; CPU backend |
| LLM Runtime | flutter_gemma (MediaPipe) | Google's official on-device inference; streaming output |
| RAG Retrieval | SQLite FTS5 (BM25) | Built into sqflite; zero extra dependencies; sub-50ms |
| Semantic Bridge | Query Expansion (pure Dart) | 130+ survival synonyms; zero memory; replaces neural embeddings |
| Retrieval Merge | Reciprocal Rank Fusion (K=60) | Merges BM25 exact + BM25 expanded + future dense signals |
| State management | Riverpod 2.x | Constructor-injectable, testable |
| Docs hosting | GitHub public repo | Free, community PR workflow |
| Distribution | Direct APK sideload | Works via USB in regions with restricted internet |

---

## Code Navigation

```
lib/
├── main.dart                        App entry + _EntryRouter
│
├── models/
│   ├── chat_message.dart            ChatMessage (role, content, timestamp)
│   ├── doc_chunk.dart               DocChunk + DocTopic enum
│   └── doc_manifest.dart            DocManifest, ModelInfo, DocEntry
│
├── services/
│   ├── llm_service.dart             flutter_gemma wrapper — loadModel(), chat() stream
│   ├── database_service.dart        SQLite schema + all CRUD (docs, chunks, FTS5)
│   ├── chunker_service.dart         Markdown → 300-token chunks with 50-token overlap
│   ├── rag_service.dart             3-way RRF retrieval (BM25 exact + expanded + dense)
│   ├── embedding_service.dart       Stub — returns empty; dense retrieval falls back gracefully
│   ├── sync_service.dart            WiFi-gated GitHub sync
│   ├── download_service.dart        Resumable HTTP downloads + SHA-256 verification
│   └── query_expander.dart          130+ survival-domain synonym expansion
│
├── providers/
│   └── providers.dart               Riverpod wiring for all services
│
├── screens/
│   ├── disclaimer_screen.dart       First-launch safety acknowledgement
│   ├── setup_screen.dart            WiFi → manifest → model download → doc sync → load
│   ├── home_screen.dart             Chat/Topics tabs + model status banners
│   ├── chat_screen.dart             RAG chat with streaming + trivial query filtering
│   ├── topic_browser_screen.dart    2×3 grid of topic categories
│   ├── doc_list_screen.dart         List of docs within a topic
│   ├── doc_reader_screen.dart       Full Markdown reader + "Ask AI" button
│   └── settings_screen.dart         Storage info, sync controls
│
├── utils/
│   ├── prompt_builder.dart          Instruction-last prompt template (optimized for 2B)
│   └── query_expander.dart          Domain-specific synonym expansion for RAG
│
└── widgets/
    ├── message_bubble.dart          Chat bubbles with BlinkingCursor
    └── sync_status_banner.dart      Banner for available doc updates
```

---

## Key Flows

### First Launch
`DisclaimerScreen` → acknowledge → `_EntryRouter` checks for model → `SetupScreen` fetches `manifest.json` → downloads Gemma 2B IT (~500MB, resumable, SHA-256 verified) → docs synced → model loaded → `HomeScreen`

### Every Chat Turn
User message → trivial query filter (< 3 words skip RAG) → 2-leg BM25 retrieval (original + expanded query) → RRF merge → instruction-last prompt built → Gemma streams tokens → 50ms batched UI updates

### Doc Sync
App opens with WiFi → `SyncService.checkForUpdates()` → compares manifest version → downloads only docs where SHA-256 changed → re-chunks and re-indexes in SQLite

---

## Distribution

Survive AI is distributed as a direct APK — no Play Store required. This is intentional: it allows the app to spread via USB sticks, local mesh networks, and peer-to-peer sharing in environments where app stores are inaccessible.

See [docs/INSTALLATION.md](docs/INSTALLATION.md) for sideloading instructions.

---

## Documentation

| Document | Audience | What it covers |
|---|---|---|
| [PRODUCT_OVERVIEW.md](docs/PRODUCT_OVERVIEW.md) | Stakeholders / non-technical | Problem, solution, why edge AI changes everything |
| [SYSTEM_DESIGN.md](docs/SYSTEM_DESIGN.md) | Engineers | Architecture, RAG pipeline, prompt engineering, memory safety |
| [USER_FLOWS.md](docs/USER_FLOWS.md) | Product / Engineering | User flows with ASCII diagrams |
| [DEVELOPER_GUIDELINES.md](docs/DEVELOPER_GUIDELINES.md) | Contributors | Code conventions, testing, adding docs/topics/models |
| [FUTURE_ROADMAP.md](docs/FUTURE_ROADMAP.md) | Everyone | Near/medium/long-term plans |
| [INSTALLATION.md](docs/INSTALLATION.md) | End users / NGOs | How to install, sideload, and deploy |

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
