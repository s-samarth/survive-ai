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
- **Assess your situation** — Answer 5 guided questions. The AI extracts your situation, retrieves relevant survival knowledge, and generates a prioritized action plan.
- **Step-by-step guidance** — Ask for instructions on a task and the AI walks you through it one step at a time.
- **Browse survival docs** — Read expert-written guides organized by topic: War, Medical, Jungle, Desert, Urban, General.
- **Persistent plans** — Action plans survive app kills and reboots. Check off steps as you complete them.
- **Silent sync** — When WiFi is available, the app silently checks for updated survival docs and downloads only what changed.

All computation runs locally. No account. No subscription. No tracking. No cloud.

---

## Why Now

Three things converged in 2026 to make this possible:

1. **Geopolitical instability at a 30-year high.** Active conflicts affect tens of millions of civilians who need survival knowledge but lack reliable internet.
2. **Smartphone penetration in conflict regions is high.** 60–80% of people in affected areas carry Android smartphones — the hardware is already in their hands.
3. **On-device AI is finally capable enough.** Gemma 3 1B runs on a mid-range Android with 3GB RAM. A 500MB download is all it takes.

---

## Technology

| Component | Choice | Why |
|---|---|---|
| Framework | Flutter (Dart) | Cross-platform, strong FFI for llama.cpp, Material 3 |
| On-device LLM | Gemma 3 1B (Q4_K_M, ~500MB) | Runs on Snapdragon 665+ (3GB RAM); great reasoning for the size |
| LLM Runtime | llama_cpp_dart 0.2.2 | Flutter wrapper for llama.cpp via dart:ffi; streaming token output |
| RAG — Phase 1 | SQLite FTS5 (BM25) | Built into sqflite; zero extra model; great for keyword-heavy survival docs |
| RAG — Phase 2 | sqlite-vec + all-MiniLM-L6-v2 ONNX | Semantic search (planned); bridges keyword gaps like "can't breathe" → "respiratory distress" |
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
│  ChatScreen │ TopicBrowserScreen │ SituationScreen      │
│  ActionPlanScreen │ StepGuideScreen │ SettingsScreen    │
│                        │                               │
│  AgentOrchestrator  ←──┤                               │
│  Intent: CHAT / ASSESS / GUIDE                          │
│                        │                               │
│  ┌─────────────┐  ┌────┴────────────┐  ┌────────────┐  │
│  │ LlmService  │  │   RagService    │  │ SyncService│  │
│  │ (llama.cpp) │  │ BM25 via FTS5   │  │ WiFi-gated │  │
│  └─────────────┘  └────────────────┘  └────────────┘  │
│                          │                              │
│                   DatabaseService                       │
│            (SQLite: chunks, fts, docs,                 │
│             action_plans, action_steps)                 │
│                                                         │
│  /files/models/model.gguf     (~500MB)                 │
│  /files/docs/{topic}/*.md     (~20MB)                  │
│  /files/survive_ai.db         (~10MB)                  │
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
│   ├── action_plan.dart             ActionPlan, ActionStep, StepPriority
│   ├── chat_message.dart            ChatMessage (role, content, timestamp)
│   ├── doc_chunk.dart               DocChunk + DocTopic enum (war/medical/jungle/desert/urban/general)
│   ├── doc_manifest.dart            DocManifest, ModelInfo, DocEntry (manifest.json schema)
│   └── situation.dart               Situation + relevantTopics() for RAG scoping
│
├── services/
│   ├── llm_service.dart             LlamaParent wrapper — loadModel(), chat() stream
│   ├── database_service.dart        SQLite schema + all CRUD (chunks, FTS5, docs, plans)
│   ├── chunker_service.dart         Markdown → 300-token chunks with 50-token overlap
│   ├── rag_service.dart             BM25 retrieval — retrieve(), retrieveForSituation()
│   ├── sync_service.dart            WiFi-gated GitHub sync — checkForUpdates(), syncNow()
│   ├── download_service.dart        Resumable HTTP downloads + SHA-256 verification
│   ├── situation_assessor.dart      5 hardcoded assessment questions + buildRawDescription()
│   └── agent_orchestrator.dart      AgentIntent enum + parseIntent()
│
├── providers/
│   └── providers.dart               Riverpod providers for all services + llmReadyProvider
│
├── screens/
│   ├── disclaimer_screen.dart       First-launch safety acknowledgement
│   ├── setup_screen.dart            WiFi check → manifest → model download → doc sync → load
│   ├── home_screen.dart             Main screen: Chat/Topics tabs + Assess FAB + sync banner
│   ├── chat_screen.dart             RAG chat with intent classification (CHAT/ASSESS/GUIDE)
│   ├── topic_browser_screen.dart    2×3 grid of topic categories
│   ├── doc_list_screen.dart         List of docs within a topic
│   ├── doc_reader_screen.dart       Full Markdown reader + "Ask AI" button
│   ├── situation_screen.dart        5-question interview → LLM extraction → plan generation
│   ├── action_plan_screen.dart      Persistent checklist with priority badges + checkboxes
│   ├── step_guide_screen.dart       One-step-at-a-time guidance with Next/Back navigation
│   └── settings_screen.dart        Storage info, sync controls, app version
│
├── utils/
│   └── prompt_builder.dart          All 4 Gemma 3 prompt templates (chat/intent/situation/plan)
│
└── widgets/
    ├── message_bubble.dart          Chat bubbles with BlinkingCursor during streaming
    └── sync_status_banner.dart      Banner shown when new docs are available

docs/
├── PRODUCT_OVERVIEW.md             CEO-level brief: problem, solution, why now, target users
├── SYSTEM_DESIGN.md                Architecture, component contracts, RAG pipeline, DB schema
├── USER_FLOWS.md                   7 detailed flows with ASCII diagrams
├── DEVELOPER_GUIDELINES.md         Code conventions, testing, how to add docs/topics/models
├── FUTURE_ROADMAP.md               Near/medium/long-term plans
└── INSTALLATION.md                 How to install, run, deploy, and sideload the APK
```

---

## Key Flows

### First Launch
`DisclaimerScreen` → acknowledge → `_EntryRouter` checks for model file → `SetupScreen` fetches `manifest.json` → downloads Gemma 3 1B (~500MB, resumable) → SHA-256 verified → docs synced → model loaded → `HomeScreen`

### Every Chat Turn
User message → intent classified as CHAT/ASSESS/GUIDE → CHAT: BM25 RAG (top-4 chunks) + prompt built + Gemma streams tokens → ASSESS: navigate to `SituationScreen` → GUIDE: generate steps + navigate to `StepGuideScreen`

### Situation Assessment
5 hardcoded questions (no LLM) → LLM extracts structured JSON → `situation.relevantTopics()` scopes RAG → LLM generates numbered action plan → steps parsed and saved to SQLite → `ActionPlanScreen`

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
| [PRODUCT_OVERVIEW.md](docs/PRODUCT_OVERVIEW.md) | Stakeholders / non-technical | Problem, solution, differentiators, target users |
| [SYSTEM_DESIGN.md](docs/SYSTEM_DESIGN.md) | Engineers | Architecture, component contracts, RAG pipeline, DB schema, prompt templates |
| [USER_FLOWS.md](docs/USER_FLOWS.md) | Product / Engineering | All 7 user flows with ASCII diagrams |
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
