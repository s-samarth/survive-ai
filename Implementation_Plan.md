Survive AI — Implementation Plan
Context
Building an offline-first Android app for people in conflict zones (inspired by the Iran war situation) who have no network access. The app provides survival guidance via an on-device small language model (SLM) augmented with curated survival docs (RAG). Users download the app + model once over WiFi, then use it fully offline indefinitely. Survival docs are community-curated on a separate public GitHub repo.

User profile: ML/AI expert (3 years at Microsoft), zero mobile experience, basic web knowledge.

Tech Stack
Component	Choice	Reason
Framework	Flutter (Dart)	No mobile experience — Flutter's widget model is easier than Kotlin; strong FFI for llama.cpp
On-device LLM	Gemma 3 1B (Q4_K_M, ~500MB)	Runs on mid-range Android (3GB RAM); fits target hardware in conflict regions; better than Phi-3 Mini (too large)
LLM runtime	llama_cpp_dart	Flutter package wrapping llama.cpp via dart:ffi; streaming token output
RAG — Phase 1	SQLite FTS5 (BM25)	No extra model; great for keyword-heavy survival docs; built into sqflite
RAG — Phase 2	sqlite-vec + all-MiniLM-L6-v2 ONNX (~22MB)	Semantic search for when keywords don't match
State management	Riverpod	Simpler than Bloc; good for someone new to Flutter
Docs hosting	GitHub public repo	Free; community PR workflow; raw URLs for direct file downloads
Distribution	Direct APK sideload	No Play Store; critical for regions with restricted internet
Cost	$0	All open-source, free hosting
System Architecture

┌─────────────────────────────────────────────────────────┐
│                  SURVIVE AI — ANDROID                   │
│                                                         │
│  UI: ChatScreen / SituationScreen / TopicBrowser        │
│         │                                               │
│  AgentOrchestrator (intent: CHAT / ASSESS / GUIDE)      │
│         │                                               │
│  ┌──────┴──────┐    ┌─────────────────────────┐         │
│  │ LlmService  │    │      RagService          │         │
│  │ (llama.cpp) │    │  BM25 (FTS5) + Vec       │         │
│  └─────────────┘    └─────────────────────────┘         │
│                              │                          │
│                       SQLite DB                         │
│                    /models/ (GGUF)                      │
│                    /docs/ (.md files)                   │
└──────────────────────────────┬──────────────────────────┘
                               │ WiFi only
                    GitHub: survive-ai-docs
                    (manifest.json + docs/)
Phased Roadmap
Phase 0 — Flutter Setup
Install Flutter, run Hello World on emulator + physical device
Set up pubspec.yaml with all dependencies (see Critical Files)
Configure android/app/build.gradle: minSdk 24, abiFilters ["arm64-v8a", "armeabi-v7a"]
Add permissions to AndroidManifest.xml: INTERNET, WRITE_EXTERNAL_STORAGE
Phase 1 — On-Device LLM Chat
Milestone: User asks a question, Gemma 3 1B streams a response. Fully offline.

Key files:

lib/services/llm_service.dart — load model, stream tokens via llama_cpp_dart
lib/utils/prompt_builder.dart — Gemma 3 chat format (<start_of_turn>system/user/model)
lib/screens/chat_screen.dart — streaming message bubbles
lib/providers/llm_provider.dart — Riverpod wrapper
Model download: on first launch, fetch URL from manifest.json on GitHub. Resumable download via HTTP Range header. SHA-256 verify on completion.

Phase 2 — Survival Docs + RAG
Milestone: User asks "How do I find water in the jungle?" — app retrieves relevant doc chunks, injects into context, LLM answers using that content.

Key files:

lib/services/database_service.dart — SQLite schema (see schema below)
lib/services/chunker_service.dart — Markdown → 300-token chunks with 50-token overlap, split at headings first
lib/services/bm25_service.dart — FTS5 keyword search
lib/services/rag_service.dart — retrieve top-4 chunks → assemble context string
lib/screens/topic_browser_screen.dart — browse docs by category
SQLite schema (critical):


CREATE VIRTUAL TABLE chunks_fts USING fts5(chunk_id UNINDEXED, topic, heading_path, body, tokenize='porter ascii');
CREATE TABLE chunks (id TEXT PRIMARY KEY, doc_id TEXT, topic TEXT, heading_path TEXT, body TEXT, chunk_index INTEGER, embedding BLOB);
CREATE TABLE docs (id TEXT PRIMARY KEY, filename TEXT, topic TEXT, version TEXT, checksum TEXT, last_synced INTEGER);
Context budget (Gemma 3 1B has 8192 token context):

System prompt: ~100 tokens
4 retrieved chunks × ~300 tokens: ~1200 tokens
Chat history (last 6 turns): ~800 tokens
Generation reserved: ~2000 tokens
Total used: ~4150 — comfortable headroom
Phase 3 — Agentic Features
Milestone: User says "I'm injured alone in a jungle" → guided interview → structured action plan → persistent checklist.

Key files:

lib/services/situation_assessor.dart — 5 hardcoded questions (no LLM for questions = deterministic + fast)
lib/services/step_planner.dart — RAG + LLM → numbered plan → parse into ActionStep objects
lib/services/agent_orchestrator.dart — state machine: IDLE → INTENT_CLASSIFY → CHAT/ASSESS/GUIDE
lib/screens/action_plan_screen.dart — persistent checklist (survives app kill/reopen)
Intent classification: single LLM call before each turn: "Reply with one word: CHAT, ASSESS, or GUIDE"

Action plan persistence:


CREATE TABLE action_plans (id TEXT PRIMARY KEY, created_at INTEGER, situation_json TEXT, is_active INTEGER);
CREATE TABLE action_steps (id TEXT PRIMARY KEY, plan_id TEXT, step_index INTEGER, priority TEXT, title TEXT, detail TEXT, is_completed INTEGER DEFAULT 0);
Phase 4 — Sync + Polish
Milestone: App detects WiFi, fetches manifest.json, downloads only changed docs, re-indexes. Clean distributable APK.

Key files:

lib/services/sync_service.dart — WiFi-gated orchestrator (connectivity_plus)
lib/services/manifest_service.dart — fetch + parse manifest.json
lib/services/download_service.dart — download .md files, SHA-256 verify
lib/widgets/sync_status_banner.dart — "Last synced 2 days ago" / "Syncing..."
INSTALL.md — sideload instructions with screenshots
Docs GitHub Repo Structure (survive-ai-docs)

survive-ai-docs/
├── manifest.json          ← machine-readable index with model URL + all doc metadata
└── docs/
    ├── war/               ← ambush_response.md, checkpoint_crossing.md, ...
    ├── medical/           ← tourniquet.md, shock_treatment.md, wound_packing.md, ...
    ├── jungle/            ← water_finding.md, shelter_building.md, navigation.md, ...
    ├── desert/            ← heat_management.md, water_conservation.md
    ├── urban/             ← building_search.md, escape_routes.md
    └── general/           ← fire_starting.md, signaling_rescue.md, psychology.md
manifest.json includes the model download URL — this means the model can be upgraded in the future without an app update, just a manifest change.

Critical Files to Create
File	Importance
pubspec.yaml	All deps: llama_cpp_dart, sqflite, flutter_riverpod, http, connectivity_plus, crypto, path_provider
lib/services/llm_service.dart	Highest-risk; wraps llama_cpp_dart FFI; everything depends on this
lib/services/database_service.dart	Owns entire SQLite schema; mistakes cascade to data loss
lib/services/rag_service.dart	Response quality depends entirely on retrieval quality
lib/services/agent_orchestrator.dart	Core state machine; architectural mistakes require full rewrite
lib/utils/prompt_builder.dart	Gemma 3 prompt format; wrong format = garbage output
Key Risks
Risk	Mitigation
llama.cpp too slow on low-end devices	Benchmark on Snapdragon 665 early; fallback to Q3_K_M if needed; hardcoded static answers if OOM
Model download fails midway	HTTP Range-based resumable download; retry on SHA-256 mismatch
LLM gives dangerous medical advice	System prompt disclaimer; mandatory acknowledgment screen on first launch
Docs become stale/wrong via community PRs	Branch protection + required review; REVIEWING.md content standards; recruit SME maintainers
User unfamiliar with APK sideload	INSTALL.md with screenshots bundled with APK
Documentation Artifacts to Create
These files will be created in the repo as part of implementation. All are Markdown, version-controlled alongside code.

1. docs/PRODUCT_OVERVIEW.md — CEO / Stakeholder Brief
A non-technical executive summary covering:

The Problem: Millions of people caught in war zones (Gaza, Iran, Sudan, Ukraine) and disaster scenarios have no internet, no access to trained responders, and no reliable source of survival knowledge at the moment they need it most.
The Solution: Survive AI — a fully offline Android app with an on-device AI assistant trained on expert survival knowledge. Works with no internet, no account, no subscription.
Why Now: Geopolitical instability is at a 30-year high. Smartphone penetration in conflict regions is high (70%+). On-device AI is finally small enough to run on a mid-range phone.
Key Differentiators: Truly offline (not just "offline mode"), open-source survival docs (anyone can contribute), zero cost to the end user, distributable via USB with no app store.
Target Users: Civilians caught in conflict zones, journalists in hostile environments, aid workers, hikers and outdoor adventurers (secondary market).
Metrics of success: Docs downloaded, queries answered offline, situations assessed.
Future vision: Expand to mesh networking (Meshtastic/LoRa), multiple languages, medical triage features.
2. docs/USER_FLOWS.md — User Flow Documentation
Covers every major path through the app with flowchart diagrams:

Flow 1: First Launch


Open App → Disclaimer Screen (acknowledge) → WiFi detected?
  ├── Yes → Download manifest.json → Download Gemma 3 1B (~500MB, progress bar) → Index docs → Home Screen
  └── No  → "Connect to WiFi to download AI model" → wait / retry
Flow 2: Offline Chat (primary)


Home → Chat tab → Type question → Intent classified as CHAT
→ RAG retrieves top-4 chunks → LLM generates streamed response
→ Response shown with source doc citations
→ User can tap citation to read full doc
Flow 3: Situation Assessment (agentic)


Home → "Assess My Situation" button → SituationScreen
→ Q1: Where are you? → Q2: Injuries? → Q3: Resources? → Q4: Companions? → Q5: Goal?
→ "Analyzing situation..." (LLM + RAG) → ActionPlanScreen
→ Prioritized checklist (CRITICAL / HIGH / MEDIUM steps)
→ Tap step → expanded detail + "Ask AI about this step"
→ Mark steps complete → plan persists on app reopen
Flow 4: Topic Browser


Home → Topics tab → Grid: [War] [Medical] [Jungle] [Desert] [Urban] [General]
→ Tap topic → List of docs in that category
→ Tap doc → Full markdown reader (offline)
→ "Ask about this doc" → scoped RAG chat
Flow 5: Sync (WiFi only)


App opens with WiFi → SyncService checks manifest.json version
→ New docs available? → Banner: "X new docs available — Sync now"
→ User taps → download only changed docs → re-index → "Up to date"
Flow 6: Step-by-Step Guidance


User says "Walk me through building a fire" → Intent: GUIDE
→ RAG retrieves fire-starting chunks → LLM generates numbered steps
→ Interactive step-by-step screen: one step at a time
→ "Next" advances, "Tell me more" opens scoped chat for that step
3. docs/FUTURE_ROADMAP.md — Future Plans
Near-term (post-MVP)

Multi-language support (Arabic, Farsi, Ukrainian — priority given conflict regions)
Gemma 3 2B option for devices with 6GB+ RAM (better reasoning)
Offline maps integration (OSM tiles downloadable by region)
Voice input/output (critical when hands are occupied or injured)
Medium-term

Mesh networking sync: share doc updates device-to-device via Bluetooth/WiFi Direct (no internet)
Offline-first medical triage module (Red Cross protocol integration)
Partner with NGOs (MSF, IRC, UN OCHA) to co-create verified doc sets
iOS port (Flutter makes this straightforward once Android is stable)
Long-term

Hardware integration: compass, GPS, barometric sensor used by agentic features
Community translation platform for survival docs
Government/humanitarian org partnerships for pre-loading on aid devices
Satellite connectivity fallback (Starlink, Iridium) for model updates in remote areas
4. docs/SYSTEM_DESIGN.md — System Design Documentation
Full technical system design covering:

Data flow diagrams (ASCII):

First launch setup flow
Per-query RAG pipeline (detailed, with token counts at each stage)
Sync pipeline (manifest fetch → diff → download → checksum → ingest → index)
Agentic orchestration state machine
Component contracts (interface definitions for each service):


LlmService: loadModel(path) / chat(prompt) → Stream<String> / dispose()
RagService: retrieve(query, topK, topicFilter?) → List<DocChunk>
DatabaseService: insertChunks / searchFts / getChunks / saveActionPlan / getActivePlan
SyncService: checkForUpdates() → SyncStatus / syncNow() → SyncResult
ChunkerService: chunk(markdownText, docId, topic) → List<DocChunk>
Storage layout:


/data/user/0/{app}/files/
├── models/
│   └── gemma-3-1b-it-Q4_K_M.gguf   (~500MB)
├── docs/
│   ├── manifest.json
│   ├── war/ambush_response.md
│   ├── medical/tourniquet.md
│   └── ...
└── survive_ai.db                    (SQLite: chunks, fts, docs, action_plans)
Prompt templates (exact strings used for each LLM call type):

RAG-augmented chat
Intent classification
Situation JSON extraction
Action plan generation
Performance targets:

Model load time: < 5s on Snapdragon 720G
First token latency: < 3s
Token generation: ≥ 3 tokens/sec on Snapdragon 665
RAG retrieval: < 200ms for BM25
Security considerations:

No PII collected (fully local, no analytics, no crash reporting unless user opts in)
All network calls are to GitHub raw URLs (public, no auth)
APK signing: release build signed with a key the maintainer controls; checksum published alongside APK
5. docs/DEVELOPER_GUIDELINES.md — Developer Guidelines
Project structure conventions:


lib/
├── models/        ← Pure data classes. No logic. No Flutter imports.
├── services/      ← Business logic. No UI. No Riverpod. Injectable.
├── providers/     ← Riverpod providers wrapping services. Thin layer.
├── screens/       ← Full-page widgets. One file per screen.
├── widgets/       ← Reusable UI components. Stateless where possible.
└── utils/         ← Pure functions. No state. No Flutter imports.
Code style:

Follow flutter_lints (included in pubspec). Zero lint warnings in CI.
All services take dependencies via constructor (no service locators / GetIt)
Service classes must be disposable: implement dispose() if they hold resources
No business logic in widgets. Widgets read from providers, dispatch events.
Adding a new survival doc:

Write the doc in Markdown following the template in CONTRIBUTING.md
Place in the correct docs/{topic}/ folder in survive-ai-docs repo
Update manifest.json with new entry (increment version, add SHA-256)
Open a PR — requires 1 maintainer review
Adding a new topic category:

Add the folder in survive-ai-docs/docs/{new_topic}/
Add the category to manifest.json schema
Add the topic tile to topic_grid.dart in the Flutter app
Update TopicFilter enum in lib/models/doc_chunk.dart
Testing approach:

Services: unit tested in isolation with mock dependencies (mockito)
RAG pipeline: integration test with 3 seed docs loaded into in-memory SQLite
LLM inference: not unit tested (non-deterministic); tested manually against benchmark prompts
UI: widget tests for critical flows (first launch, situation assessment)
CI (GitHub Actions):

On every PR: flutter analyze, flutter test, build release APK
On merge to main: build and attach signed APK as GitHub release asset
Docs repo CI: validate manifest.json schema on every PR
Release process:

Bump version in pubspec.yaml and manifest.json
Tag release on GitHub: git tag v1.x.x
GitHub Actions builds and signs APK
Attach APK to GitHub Release with SHA-256 checksum in release notes
Users download directly from GitHub Releases page
Verification
Phase 1: Copy Gemma 3 1B GGUF to device manually → open app → ask "how do I treat a wound?" → verify streamed response, no internet required
Phase 2: Add 3 markdown docs → restart app → ask doc-specific question → verify response contains info from docs (not hallucinated)
Phase 3: Trigger assessment flow → complete 5 questions → verify action plan is saved in SQLite → kill app → reopen → verify plan is still there with step state
Phase 4: Enable WiFi → check sync banner → add a new doc to GitHub repo → trigger manual sync in settings → verify new doc is downloaded and queryable
