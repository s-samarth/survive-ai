# Survive AI

> An offline-first AI survival assistant for people in conflict zones, disaster scenarios, and wilderness emergencies. Works with no internet after a one-time WiFi setup.

---

## The Problem

Every year, millions of people find themselves in life-threatening situations with no internet access and no trained responders nearby — civilians in conflict zones in Ukraine, Gaza, Sudan, and Iran; aid workers in remote areas; journalists in hostile environments; hikers stranded in the wilderness.

In these moments, people need clear, expert guidance. But they can't Google it. They can't call an expert. Their connection is gone.

**There is no reliable, offline-capable AI assistant built for survival. Until now.**

---

## What Survive AI Does

Survive AI is a fully offline Android app that puts an expert survival assistant in your pocket with no internet required after setup.

- **Ask anything** — "How do I treat a deep wound?" "How do I find water in the jungle?" "What do I do if I'm under fire?"
- **RAG-powered answers** — Every response is grounded in expert-written survival docs retrieved via BM25 search.
- **Browse survival docs** — Read expert-written guides organized by topic: War, Medical, Jungle, Desert, Urban, General.
- **Silent sync** — When WiFi is available, the app silently checks for updated survival docs and downloads only what changed.

All computation runs locally. No account. No subscription. No tracking. No cloud.

---

## Why Now

Three things converged in 2026 to make this possible:

1. **Geopolitical instability at a 30-year high.** Active conflicts affect tens of millions of civilians who need survival knowledge but lack reliable internet.
2. **Smartphone penetration in conflict regions is high.** 60–80% of people in affected areas carry Android smartphones — the hardware is already in their hands.
3. **On-device AI is finally capable enough.** Gemma 2B runs on a mid-range Android with 3GB RAM. A ~500MB download is all it takes.

---

## Technology

| Component | Choice | Why |
|---|---|---|
| Framework | Flutter (Dart) | Cross-platform, Material 3 |
| On-device LLM | Gemma 2B IT (int4, ~500MB) | Runs on mid-range Android (3GB RAM); CPU backend to prevent OOM on 4GB devices |
| LLM Runtime | flutter_gemma (MediaPipe LLM Inference) | Google's official on-device inference; streaming token output |
| RAG | SQLite FTS5 (BM25, field-weighted) | Built into sqflite; zero extra model; heading 2x, body 1.5x weighting |
| State management | Riverpod 2.x | Simple, testable, constructor-injectable |
| Docs hosting | GitHub public repo | Free; community PR workflow; raw URLs for direct downloads |
| Distribution | Direct APK sideload | No Play Store; works via USB in regions with restricted internet |

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│                  SURVIVE AI — ANDROID                   │
│                                                         │
│  UI Layer (Flutter / Riverpod)                          │
│  DisclaimerScreen → SetupScreen → HomeScreen            │
│  ChatScreen │ TopicBrowserScreen │ SettingsScreen       │
│                        │                               │
│  ┌─────────────┐  ┌───┴─────────────┐  ┌────────────┐  │
│  │ LlmService  │  │   RagService    │  │ SyncService│  │
│  │(flutter_gem │  │ BM25 via FTS5   │  │ WiFi-gated │  │
│  │ ma/MediaPipe│  │ (field-weighted)│  │            │  │
│  │  LLM)      │  │                 │  │            │  │
│  └─────────────┘  └────────────────┘  └────────────┘  │
│                          │                              │
│                   DatabaseService                       │
│            (SQLite: docs, chunks, chunks_fts)           │
│                                                         │
│  /files/models/gemma-2b-it-cpu-int4.bin  (~500MB)      │
│  /files/docs/{topic}/*.md                (~20MB)       │
│  /files/survive_ai.db                    (~10MB)       │
└──────────────────────┬──────────────────────────────────┘
                       │ WiFi only (sync + first launch)
              GitHub: survive-ai-docs
              manifest.json + docs/
```

---

## Code Navigation

```
lib/
├── main.dart                        App entry + _EntryRouter (first-launch routing)
│
├── models/
│   ├── chat_message.dart            ChatMessage (role, content, timestamp)
│   ├── doc_chunk.dart               DocChunk + DocTopic enum (war/medical/jungle/desert/urban/general)
│   └── doc_manifest.dart            DocManifest, ModelInfo, DocEntry (manifest.json schema)
│
├── services/
│   ├── llm_service.dart             flutter_gemma wrapper — loadModel(), chat() stream
│   ├── database_service.dart        SQLite schema + all CRUD (docs, chunks, FTS5)
│   ├── chunker_service.dart         Markdown → 300-token chunks with 50-token overlap
│   ├── rag_service.dart             BM25 retrieval — retrieve() with field-weighted scoring
│   ├── sync_service.dart            WiFi-gated GitHub sync — checkForUpdates(), syncNow()
│   ├── download_service.dart        Resumable HTTP downloads + SHA-256 verification
│   └── embedding_service.dart       Stub — always returns empty, BM25 fallback
│
├── providers/
│   └── providers.dart               Riverpod providers for all services + llmReadyProvider
│
├── screens/
│   ├── disclaimer_screen.dart       First-launch safety acknowledgement
│   ├── setup_screen.dart            WiFi check → manifest → model download → doc sync → load
│   ├── home_screen.dart             Main screen: Chat/Topics tabs + sync banner
│   ├── chat_screen.dart             RAG chat — BM25 retrieval + Gemma streaming
│   ├── topic_browser_screen.dart    2×3 grid of topic categories
│   ├── doc_list_screen.dart         List of docs within a topic
│   ├── doc_reader_screen.dart       Full Markdown reader + "Ask AI" button
│   └── settings_screen.dart        Storage info, sync controls, app version
│
├── utils/
│   └── prompt_builder.dart          Gemma prompt templates (chat with RAG context)
│
└── widgets/
    ├── message_bubble.dart          Chat bubbles with BlinkingCursor during streaming
    └── sync_status_banner.dart      Banner shown when new docs are available

docs/
├── PRODUCT_OVERVIEW.md             CEO-level brief: problem, solution, why now, target users
├── SYSTEM_DESIGN.md                Architecture, component contracts, RAG pipeline, DB schema
├── USER_FLOWS.md                   Detailed flows with ASCII diagrams
├── DEVELOPER_GUIDELINES.md         Code conventions, testing, how to add docs/topics/models
├── FUTURE_ROADMAP.md               Near/medium/long-term plans
└── INSTALLATION.md                 How to install, run, deploy, and sideload the APK
```

---

## Key Flows

### First Launch
`DisclaimerScreen` → acknowledge → `_EntryRouter` checks for model file → `SetupScreen` fetches `manifest.json` → downloads Gemma 2B IT (~500MB, resumable) → SHA-256 verified → docs synced → model loaded → `HomeScreen`

### Every Chat Turn
User message → BM25 RAG retrieval (top-4 chunks, field-weighted: heading 2x, body 1.5x) → prompt built with context between `[CONTEXT]` tags → Gemma streams tokens back to UI

### Doc Sync
App opens with WiFi → `SyncService.checkForUpdates()` → compares manifest version → downloads only docs where SHA-256 changed → re-chunks and re-indexes in SQLite

---

## Model Config

- **Model:** Gemma 2B IT, int4 quantization, CPU backend
- **File:** `gemma-2b-it-cpu-int4.bin` (~500MB)
- **Runtime:** flutter_gemma (MediaPipe LLM Inference)
- **Context:** 4096 tokens, 512-token max output
- **Sampling:** temp=0.7, top_k=40
- **Build target:** `android-arm64` only

---

## Distribution

Survive AI is distributed as a direct APK — no Play Store required. This is intentional: it allows the app to spread via USB sticks, local mesh networks, and peer-to-peer sharing in environments where app stores are inaccessible.

See [docs/INSTALLATION.md](docs/INSTALLATION.md) for sideloading instructions.

---

## Documentation

| Document | Audience | What it covers |
|---|---|---|
| [PRODUCT_OVERVIEW.md](docs/PRODUCT_OVERVIEW.md) | Stakeholders / non-technical | Problem, solution, differentiators, target users |
| [SYSTEM_DESIGN.md](docs/SYSTEM_DESIGN.md) | Engineers | Architecture, component contracts, RAG pipeline, DB schema |
| [USER_FLOWS.md](docs/USER_FLOWS.md) | Product / Engineering | User flows with ASCII diagrams |
| [DEVELOPER_GUIDELINES.md](docs/DEVELOPER_GUIDELINES.md) | Contributors | Code conventions, architecture rules, testing, adding docs |
| [FUTURE_ROADMAP.md](docs/FUTURE_ROADMAP.md) | Everyone | Near/medium/long-term vision |
| [INSTALLATION.md](docs/INSTALLATION.md) | End users / NGOs | How to install, sideload, and deploy the app |

---

## Contributing

Survive AI welcomes contributions from developers, survival experts, medics, translators, and field workers.

- **App code** — open a PR to this repo. Follow the [Developer Guidelines](docs/DEVELOPER_GUIDELINES.md).
- **Survival docs** — contribute to the [survive-ai-docs](https://github.com/survive-ai/survive-ai-docs) repo. All doc PRs require maintainer review. Medical content requires subject matter expert review.

**What we will not build:** real-time communication, location tracking, telemetry, paid features, AI-generated medication prescriptions, or political content. See [FUTURE_ROADMAP.md](docs/FUTURE_ROADMAP.md) for the complete list.

---

## License

Open-source. Humanitarian mission. Free forever.

**Maintainer:** [@samarthsaraswat](https://github.com/samarthsaraswat)
**Bug reports:** [github.com/survive-ai/survive-ai/issues](https://github.com/survive-ai/survive-ai/issues)
**Security vulnerabilities:** email directly — do not open a public issue.
