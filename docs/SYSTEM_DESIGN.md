# System Design — Survive AI

## Overview

Survive AI is a fully offline Android application that runs an AI survival assistant on a 4GB edge device. After a one-time WiFi setup, all computation runs locally — there is no backend server, no cloud database, no API calls during normal operation.

Every architectural choice in this system is driven by a single constraint: **this must work on a 4GB Android phone, in a survival emergency, where speed is the difference between life and death.**

---

## Design Philosophy: Why Simple Beats Sophisticated

Cloud-based AI systems optimize for accuracy. They can use massive models, ensemble retrievers, multi-stage pipelines, and expensive rerankers. Survive AI cannot use any of that. The constraints are:

1. **4GB total device RAM** — Android OS takes ~1.5GB, the LLM takes ~1.6GB, leaving ~900MB for everything else
2. **No network at runtime** — the app must function as if the internet will never come back
3. **Speed over sophistication** — a person with a gunshot wound needs an answer in 3 seconds, not 30
4. **Zero additional ML models** — any second model alongside Gemma triggers Android's OOM killer

These constraints lead to decisions that would look "wrong" in a cloud system but are exactly right for this use case:

| Cloud approach | Our approach | Why |
|---|---|---|
| Vector embeddings (BERT, MiniLM) | Query expansion (pure Dart dictionary) | Zero memory overhead; 130+ survival synonyms bridge vocabulary gaps |
| Long system prompt (~1000 tokens) | Short instruction (~60 tokens) at end of prompt | 2B models forget instructions at the top; attention is strongest near generation point |
| GPU inference for speed | CPU inference only | GPU uses shared memory on Android; CPU uses pageable RAM that the OS can manage |
| Persistent sessions with KV cache | Fresh session every turn, KV cache recycled | Prevents memory accumulation; keeps RAM usage flat regardless of conversation length |
| Complex reranking pipeline | Reciprocal Rank Fusion (RRF) | Single-pass merge with no additional model; gracefully degrades if signals are missing |

---

## High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                   SURVIVE AI — 4GB ANDROID DEVICE                    │
│                                                                      │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │                     UI Layer (Flutter)                        │   │
│  │  DisclaimerScreen  SetupScreen  HomeScreen  ChatScreen        │   │
│  │  TopicBrowserScreen  DocListScreen  DocReaderScreen           │   │
│  │  SettingsScreen                                               │   │
│  └──────────────────────────┬───────────────────────────────────┘   │
│                              │ Riverpod providers                    │
│  ┌──────────────────────────▼───────────────────────────────────┐   │
│  │                    Service Layer (Dart)                        │   │
│  │                                                               │   │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐   │   │
│  │  │  LlmService  │  │  RagService  │  │   SyncService    │   │   │
│  │  │ Gemma 2B IT  │  │ 2-leg BM25   │  │  WiFi-gated      │   │   │
│  │  │ CPU backend  │  │ + RRF merge  │  │  GitHub sync     │   │   │
│  │  └──────┬───────┘  └──────┬───────┘  └────────┬─────────┘   │   │
│  │         │                 │                    │             │   │
│  │  ┌──────┴─────┐  ┌───────┴────────┐          │             │   │
│  │  │PromptBuild │  │ QueryExpander  │          │             │   │
│  │  │(instr-last)│  │ (130+ synonyms)│          │             │   │
│  │  └────────────┘  └────────────────┘          │             │   │
│  │         │                 │                    │             │   │
│  │  ┌──────┴─────────────────┴────────────────────┴──────────┐ │   │
│  │  │              DatabaseService (SQLite)                    │ │   │
│  │  │  chunks | chunks_fts (FTS5/BM25) | docs                 │ │   │
│  │  └──────────────────────────────────────────────────────────┘ │   │
│  │                                                               │   │
│  │  ┌──────────────────┐  ┌──────────────────┐                  │   │
│  │  │  ChunkerService  │  │  DownloadService │                  │   │
│  │  │ (MD→300tok chunks)│  │ (resumable HTTP) │                  │   │
│  │  └──────────────────┘  └──────────────────┘                  │   │
│  └───────────────────────────────────────────────────────────────┘   │
│                                                                      │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │                      Storage Layer                            │   │
│  │  /files/models/gemma-2b-it-cpu-int4.bin  (~500MB model)      │   │
│  │  /files/docs/{topic}/*.md                (~20MB guides)      │   │
│  │  /files/survive_ai.db                    (~10MB SQLite)      │   │
│  └──────────────────────────────────────────────────────────────┘   │
│                                                                      │
└───────────────────────────────┬──────────────────────────────────────┘
                                │ WiFi only (one-time setup + sync)
                     ┌──────────▼─────────────┐
                     │  GitHub: survive-ai-docs│
                     │  manifest.json + docs/  │
                     └─────────────────────────┘
```

---

## Component Contracts

### LlmService

```dart
// Wraps flutter_gemma for on-device Gemma 2B IT inference.
// CPU backend only — GPU uses shared memory that causes OOM on 4GB devices.
// KV cache recycled every turn — old session nulled BEFORE new one allocates.
Future<void> loadModel(String modelPath);          // Re-activate model each launch
Stream<String> chat({required String prompt});      // Creates session, streams tokens
Future<void> disposeAsync();                       // Closes session and model
```

### RagService

```dart
// 3-way Reciprocal Rank Fusion retrieval:
//   Leg 1: BM25 on original query (exact keyword matching)
//   Leg 2: BM25 on expanded query (synonym/related term matching via QueryExpander)
//   Leg 3: Dense embeddings (stubbed — returns empty, falls back gracefully)
Future<List<DocChunk>> retrieve(String query, {int topK = 4, String? topicFilter});
Future<List<DocChunk>> retrieveForSituation(String query, List<String> topics, {int topK = 6});
```

### QueryExpander

```dart
// Pure Dart synonym expansion — zero memory, sub-millisecond.
// Maps 130+ survival-domain trigger terms to related terms.
// Example: "bleeding" → "bleeding hemorrhage wound blood tourniquet pressure dressing bandage"
// Includes simple stemming (strips -ing, -ed, -ly, -s) for broader matching.
// Expansion capped at 8 terms to avoid query dilution.
static String expand(String query);
```

### PromptBuilder

```dart
// Instruction-last prompt structure optimized for 2B models.
// Layout: (1) RAG reference material, (2) history, (3) instruction, (4) question.
// Returns PLAIN TEXT — flutter_gemma adds turn markers automatically.
// Token budget: 3500 max (4096 context − 512 output − 84 safety).
static String buildChatPrompt({
  required List<DocChunk> chunks,
  required List<ChatMessage> history,
  required String userMessage,
});
```

### DatabaseService

```dart
Future<void> insertChunks(List<DocChunk> chunks);
Future<void> deleteChunksForDoc(String docId);
Future<List<String>> searchFts(String query, {String? topicFilter, int limit = 20});
Future<List<DocChunk>> getChunksByIds(List<String> ids);
Future<void> upsertDoc(Map<String, dynamic> docMap);
Future<String?> getDocVersion(String docId);
Future<List<Map<String, dynamic>>> getDocsByTopic(String topic);
```

### SyncService

```dart
Future<bool> isOnline();
Future<SyncStatus> checkForUpdates();
Future<SyncResult> syncNow({void Function(int, int)? onProgress});
```

---

## RAG Pipeline — End-to-End

### Ingestion (at sync time)

```
GitHub .md file downloaded
    │
    ▼
ChunkerService.chunk(markdown, docId, topic)
    │
    │ Split strategy (in order):
    │   1. At h1/h2/h3 heading boundaries
    │   2. At paragraph breaks if section > 300 tokens
    │   3. With 50-token overlap between consecutive chunks
    │
    ▼
List<DocChunk> (id, docId, topic, headingPath, body, chunkIndex)
    │
    ├── INSERT INTO chunks (metadata + body)
    └── INSERT INTO chunks_fts (chunk_id, topic, heading_path, body)
```

### Query-Time Retrieval (per user message, < 100ms total)

```
User query: "I'm bleeding badly, what do I do?"
    │
    │ Step 0: Trivial query filter
    │ If < 3 words → skip RAG, return empty chunks
    │ (prevents irrelevant context injection for "hi", "yo", etc.)
    │
    ▼
    ├─── Leg 1: BM25 exact ──────────────────────────────────────┐
    │    FTS5 MATCH "bleeding badly"                             │
    │    → chunks mentioning "bleeding", "badly"                  │
    │                                                             │
    ├─── Leg 2: BM25 expanded ───────────────────────────────────┤
    │    QueryExpander: "bleeding" → adds                         │
    │    "hemorrhage wound blood tourniquet pressure dressing"     │
    │    FTS5 MATCH expanded query                                │
    │    → chunks about tourniquet, hemorrhage control             │
    │                                                             │
    ├─── Leg 3: Dense (stub) ────────────────────────────────────┤
    │    EmbeddingService returns empty vector                    │
    │    → returns empty list (graceful fallback)                  │
    │                                                             │
    ▼                                                             │
    Reciprocal Rank Fusion (K=60)                                │
    score(chunk) = Σ_legs  1 / (rank_in_leg + 60)               │
    │                                                             │
    ▼                                                             │
    Top 4 chunks by RRF score                                    │
    │                                                             │
    ▼
PromptBuilder.buildChatPrompt(chunks, history, userMessage)
    │
    │ Instruction-last layout:
    │   [Reference material from survival guides]     ← first
    │   [medical > Tourniquet Application]
    │   Apply tourniquet 2-3 inches above wound...
    │
    │   [Previous exchange]                            ← middle
    │   Q: ...
    │   A: ...
    │
    │   You are Survive AI, an offline survival        ← right before question
    │   expert. Answer directly. Give the most
    │   critical action FIRST...
    │
    │   Question: I'm bleeding badly, what do I do?    ← last
    │
    ▼
LlmService.chat(prompt) → Stream<String> tokens
    │
    │ 50ms batched UI updates (reduces ~512 setState calls to ~25)
    │
    ▼
User sees streaming response with actionable survival guidance
```

### Why Query Expansion Instead of Neural Embeddings

The vocabulary gap between users and survival documentation is the core retrieval challenge:

| User says | Docs say | BM25 alone? | With query expansion? |
|---|---|---|---|
| "I'm bleeding" | "hemorrhage control" | Miss | Match ("bleeding" → "hemorrhage") |
| "bombs falling" | "blast shelter protocol" | Miss | Match ("bombs" → "explosion blast shelter") |
| "can't breathe" | "airway obstruction" | Miss | Match ("breathe" → "airway choking") |
| "bitten by snake" | "envenomation treatment" | Miss | Match ("bite" → "venom antivenom") |

Neural embedding models (MiniLM, USE, etc.) would solve this more elegantly, but require 200+ MB of additional RAM. On a 4GB device already running a 1.6GB LLM, this triggers Android's OOM killer.

Query expansion achieves 80% of the benefit with 0% of the memory cost:
- 130+ hand-crafted survival-domain mappings
- Simple stemming catches morphological variants ("bleeding" → "bleed" → matches "bleed" trigger)
- Runs as a pure Dart string operation — sub-millisecond, zero allocations
- The expanded query runs as a second BM25 search leg, providing an independent signal

The 3-way RRF infrastructure is built and ready — when device capabilities improve, a third dense retrieval leg can plug in without any pipeline changes.

---

## Prompt Engineering for 2B Models

### The Problem

Standard LLM prompt engineering assumes strong instruction-following (GPT-4, Claude). Gemma 2B IT is fundamentally different:

- **Limited attention span** — a 260-token system prompt at the top of the context is effectively ignored by the time the model starts generating
- **Role confusion** — "User:" and "Assistant:" labels inside a single `<start_of_turn>user` block confuse the model about who is speaking
- **Context parroting** — irrelevant RAG chunks cause the model to repeat context verbatim instead of answering the question
- **Prompt continuation** — without clear structure, the model generates more prompt text instead of a response

### The Solution: Instruction-Last Prompt Structure

```
┌───────────────────────────────────────────┐
│  Reference material (RAG chunks)          │  ← farthest from generation
│  [medical > Bleeding Control]             │     (data to reference, not follow)
│  Apply direct pressure with clean cloth...│
│                                           │
│  Previous exchange:                       │  ← middle
│  Q: How bad is it?                        │     (continuity, neutral labels)
│  A: Describe the wound and I can help...  │
│                                           │
│  You are Survive AI, an offline survival  │  ← RIGHT BEFORE generation
│  expert. Answer directly. Give the most   │     (this is what the model follows)
│  critical action FIRST...                 │
│                                           │
│  Question: The bleeding won't stop        │  ← last token before model generates
└───────────────────────────────────────────┘
```

**Why this works:** Transformer attention is not uniform. In a 2B model, the tokens near the generation point have the strongest influence on the first generated token. By placing the instruction there (not at the top), the model reliably follows it.

### Additional Prompt Optimizations

| Optimization | Rationale |
|---|---|
| Trivial query filter (< 3 words) | "hi" or "yo" skip RAG — prevents injecting irrelevant chunks that confuse the small model |
| Q:/A: history labels (not User:/Assistant:) | Avoids role confusion when history is inside a user turn block |
| History capped at 4 turns, 400 chars each | Prevents history from consuming the 3500-token budget |
| Token budget with priority allocation | Instruction + question reserved first, then context, then history — ensures critical content always fits |
| flutter_gemma handles turn markers | Prompt returned as plain text — no risk of double-wrapping `<start_of_turn>` tags |

---

## Memory Safety Architecture

### The Challenge

On a 4GB Android device with Gemma 2B IT loaded:

| Component | RAM |
|---|---|
| Android OS + system services | ~1.5 GB |
| Flutter framework + app heap | ~200 MB |
| Gemma 2B IT (INT4, mmap'd) | ~1.6 GB |
| KV attention cache (per turn) | ~200 MB |
| SQLite + FTS5 index | ~30 MB |
| **Total** | **~3.5 GB** |
| **Remaining before OOM** | **~500 MB** |

### Protections

**CPU backend (not GPU):** On Android, GPU inference uses shared memory from the same 4GB pool. The OS cannot reclaim GPU memory under pressure. CPU inference uses pageable RAM that Android can swap or reclaim, providing a pressure relief valve.

**KV cache recycling:** Each inference turn creates a fresh session. The previous session is nulled and closed BEFORE the new one allocates. Without this, both sessions exist in memory simultaneously — a 400MB spike that triggers OOM on the second+ turn.

```dart
final prev = _session;
_session = null;        // null reference FIRST
await prev?.close();    // THEN close (free memory)
_session = await _model!.createSession(...);  // THEN allocate
```

**50ms UI batching:** Without batching, every streamed token triggers a `setState()` call and a new String allocation. Over a 512-token response, that's 512 GC cycles. Batching at 50ms reduces this to ~25 updates, cutting GC pressure by ~20x.

**Stream error handling:** `getResponseAsync()` reports errors via `StreamController.addError()`. Without explicit `.handleError()`, unhandled stream errors crash the app. We convert them to catchable `StateError` exceptions shown in the UI.

**Prompt budget system:** Token budget of 3500 prevents the prompt from exceeding the 4096-token context window. Priority allocation ensures the instruction and question always fit, even if context and history must be truncated.

---

## SQLite Schema

```sql
CREATE TABLE docs (
  id TEXT PRIMARY KEY,
  filename TEXT NOT NULL,
  topic TEXT NOT NULL,
  version TEXT NOT NULL,
  checksum TEXT NOT NULL,
  last_synced INTEGER
);

CREATE TABLE chunks (
  id TEXT PRIMARY KEY,
  doc_id TEXT NOT NULL REFERENCES docs(id) ON DELETE CASCADE,
  topic TEXT NOT NULL,
  heading_path TEXT NOT NULL DEFAULT '',
  body TEXT NOT NULL,
  chunk_index INTEGER NOT NULL,
  embedding BLOB                 -- reserved for future dense retrieval
);

CREATE VIRTUAL TABLE chunks_fts USING fts5(
  chunk_id UNINDEXED,
  topic,
  heading_path,
  body,
  tokenize = 'porter ascii'
);
```

---

## Performance Targets

| Metric | Target | Why it matters |
|---|---|---|
| First token latency | < 3s | User needs immediate confirmation that help is coming |
| BM25 retrieval (4 chunks) | < 50ms | RAG overhead must be imperceptible |
| Query expansion | < 1ms | Pure Dart dictionary lookup, no ML |
| Token generation rate | >= 3 tok/sec | Readable streaming speed on low-end Snapdragon |
| Model load time | < 5s | App must be usable quickly after restart |
| App cold start to home | < 2s | User shouldn't wait to start browsing docs |

---

## Security & Privacy

- **No PII collected.** No analytics, no crash reporting, no telemetry.
- **All data is local.** Chat history and survival docs exist only on the device.
- **Network calls are read-only** to public GitHub repos. No credentials, no auth tokens.
- **Checksums on every download.** SHA-256 verified before any file is written to disk.
- **No location access.** The app never requests GPS permission.
- **APK distribution** with published signing key fingerprint for verification.

---

## Future: Dense Retrieval (When Devices Allow)

The 3-way RRF infrastructure is already built. When 6-8GB devices become the norm in conflict regions, the third retrieval leg can be activated:

1. Add an embedding model (e.g., `all-MiniLM-L6-v2` at ~22MB)
2. Implement `EmbeddingService.embedQuery()` to return real vectors instead of empty
3. The existing `_denseRetrieveWithVector()` in RagService handles cosine similarity
4. RRF merge automatically incorporates the third signal — no pipeline changes needed

The `embedding BLOB` column already exists in the `chunks` table schema. The `EmbeddingService` interface is defined. The code path is tested and falls back gracefully. Only the model itself is missing.
