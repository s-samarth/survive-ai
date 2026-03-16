# System Design — Survive AI

## Overview

Survive AI is a fully offline Android application. After a one-time WiFi setup, all computation runs locally on the device. There is no backend server, no database in the cloud, no API calls during normal operation.

---

## High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                        SURVIVE AI — ANDROID                         │
│                                                                     │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │                        UI Layer (Flutter)                   │   │
│  │  DisclaimerScreen  SetupScreen  HomeScreen  ChatScreen      │   │
│  │  TopicBrowserScreen  DocListScreen  DocReaderScreen         │   │
│  │  SettingsScreen                                             │   │
│  └──────────────────────────┬──────────────────────────────────┘   │
│                             │ Riverpod providers                    │
│  ┌──────────────────────────▼──────────────────────────────────┐   │
│  │                     Service Layer (Dart)                     │   │
│  │                                                             │   │
│  │  ┌──────────────┐  ┌─────────────┐  ┌──────────────────┐   │   │
│  │  │  LlmService  │  │  RagService │  │   SyncService    │   │   │
│  │  │(flutter_gemma)│  │  BM25       │  │  WiFi-gated      │   │   │
│  │  └──────┬───────┘  └──────┬──────┘  └────────┬─────────┘   │   │
│  │         │                 │                   │             │   │
│  │  ┌──────┴─────────────────┴───────────────────┴──────────┐ │   │
│  │  │              DatabaseService (SQLite)                  │ │   │
│  │  │  chunks | chunks_fts | docs                           │ │   │
│  │  └────────────────────────────────────────────────────────┘ │   │
│  │                                                             │   │
│  │  ┌──────────────────┐  ┌──────────────────┐                │   │
│  │  │  ChunkerService  │  │  DownloadService │                │   │
│  │  │  (Markdown→chunks│  │  (resumable HTTP)│                │   │
│  │  └──────────────────┘  └──────────────────┘                │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                                                                     │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │                     Storage Layer                           │   │
│  │  /files/models/gemma-2b-it-cpu-int4.bin (~500MB)             │   │
│  │  /files/docs/{topic}/*.md              (~20MB)              │   │
│  │  /files/survive_ai.db                  (~10MB)              │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                                                                     │
└──────────────────────────────────┬──────────────────────────────────┘
                                   │ WiFi only (sync + first launch)
                        ┌──────────▼─────────────┐
                        │  GitHub: survive-ai-docs│
                        │  manifest.json          │
                        │  docs/war/*.md          │
                        │  docs/medical/*.md      │
                        │  docs/jungle/*.md       │
                        │  ...                    │
                        └─────────────────────────┘
```

---

## Component Contracts

### LlmService

```dart
// Wraps flutter_gemma to provide model loading and token-streaming chat.
// Calls FlutterGemma.installModel + getActiveModel(maxTokens: 512, preferredBackend: cpu)
Future<void> loadModel(String modelPath);          // Re-activate model each launch
Stream<String> chat({required String prompt});      // Creates session, streams tokens, closes previous session
Future<void> disposeAsync();                       // Closes session and model
```

### RagService

```dart
// Retrieves relevant doc chunks for a query
Future<List<DocChunk>> retrieve(String query, {int topK = 4, String? topicFilter});
Future<List<DocChunk>> retrieveForSituation(String query, List<String> topics, {int topK = 6});
```

### DatabaseService

```dart
// Chunk CRUD
Future<void> insertChunks(List<DocChunk> chunks);
Future<void> deleteChunksForDoc(String docId);
Future<List<String>> searchFts(String query, {String? topicFilter, int limit = 20});
Future<List<DocChunk>> getChunksByIds(List<String> ids);

// Doc registry
Future<void> upsertDoc(Map<String, dynamic> docMap);
Future<String?> getDocVersion(String docId);
Future<List<Map<String, dynamic>>> getDocsByTopic(String topic);
```

### SyncService

```dart
Future<bool> isOnline();
Future<SyncStatus> checkForUpdates();                              // Fetch manifest, compare version
Future<SyncResult> syncNow({void Function(int, int)? onProgress}); // Download + ingest changed docs
```

### DownloadService

```dart
// Resumable HTTP download with SHA-256 verification
Future<String> download({
  required String url,
  required String filename,
  required String subfolder,
  String? expectedSha256,
  int? expectedBytes,
  void Function(int downloaded, int total)? onProgress,
});
Future<String?> getExistingFile(String filename, String subfolder);
Future<bool> verifyChecksum(String filePath, String expectedSha256);
```

### ChunkerService

```dart
// Splits Markdown into RAG-ready chunks
List<DocChunk> chunk(String markdown, String docId, String topic);
```

---

## RAG Pipeline — End-to-End

### Ingestion (at sync time, runs async)

```
GitHub .md file downloaded
    │
    ▼
ChunkerService.chunk(markdown, docId, topic)
    │
    │ Split strategy (in order):
    │   1. At h1/h2/h3 heading boundaries
    │   2. At paragraph breaks (blank lines) if section > 300 tokens
    │   3. With 50-token overlap window between chunks
    │
    ▼
List<DocChunk> (id, docId, topic, headingPath, body, chunkIndex)
    │
    ├── DatabaseService.insertChunks(chunks)
    │       → INSERT INTO chunks (metadata + body)
    │       → INSERT INTO chunks_fts (chunk_id, topic, heading_path, body)
    │
    └── DatabaseService.upsertDoc(docMap)
            → UPDATE docs SET checksum, version, last_synced
```

### Query-Time Retrieval (per user message, < 200ms)

```
User query: "How do I find water in the jungle?"
    │
    ▼
RagService.retrieve(query, topK=4, topicFilter='jungle')
    │
    ▼
DatabaseService.searchFts(query, topicFilter='jungle', limit=20)
    │
    │  SQL: SELECT chunk_id FROM chunks_fts
    │       WHERE chunks_fts MATCH 'water jungle find'
    │       AND topic = 'jungle'
    │       ORDER BY bm25(chunks_fts, 1.0, 2.0, 1.5)
    │       LIMIT 20
    │
    ▼
List<String> rankedChunkIds (top 20 by BM25 score)
    │
    ▼
DatabaseService.getChunksByIds(top 4 ids)
    │
    ▼
List<DocChunk> (with full body text)
    │
    ▼
PromptBuilder.buildChatPrompt(chunks, history, userMessage)
    │
    ▼
LlmService.chat(prompt) → Stream<String> tokens
```

### Context Window Budget (Gemma 2B IT — 8192 token context)

| Component | Estimated Tokens |
|---|---|
| System prompt + instructions | ~1200 |
| 4 retrieved chunks (300 tokens each) | ~1200 |
| Chat history (last 6 turns) | ~900 |
| User message | ~50 |
| Total input | ~3350 |
| Reserved for generation (maxTokens=512) | 512 |
| **Total used** | **~3862** |
| Available headroom | **~4330** |

The context window is comfortable. No truncation needed under normal use.

---

## Prompt Template

There is a single prompt template (RAG-augmented chat) defined in `lib/utils/prompt_builder.dart`.

### RAG-Augmented Chat

The system prompt (~800 words / ~1200 tokens) establishes Survive AI's identity, knowledge domains (war, medical, urban disasters, jungle, desert, general survival), response style, and constraints. Key directives:

- Give the most critical action first, then supporting steps by urgency
- Use [CONTEXT] chunks as primary source; supplement with general knowledge only if context is incomplete
- Never tell users to "call emergency services" as a first response
- Tone: direct, calm, clear — not institutional

```
<start_of_turn>system
You are Survive AI — a calm, expert survival assistant built for people
in genuine life-threatening emergencies. You run entirely offline...
[...full system prompt — ~800 words of detailed instructions...]

[CONTEXT]
--- From: medical/wound_care > Applying Pressure ---
{chunk_1_text}

--- From: medical/wound_care > Wound Cleaning ---
{chunk_2_text}
[/CONTEXT]
<end_of_turn>
<start_of_turn>user
How do I treat a deep wound?
<end_of_turn>
<start_of_turn>model
```

When no RAG chunks are retrieved (e.g., docs not yet synced), the `[CONTEXT]` block is omitted entirely.

---

## SQLite Schema

```sql
-- Document registry
CREATE TABLE docs (
  id TEXT PRIMARY KEY,           -- e.g. "medical/tourniquet"
  filename TEXT NOT NULL,        -- e.g. "docs/medical/tourniquet.md"
  topic TEXT NOT NULL,           -- e.g. "medical"
  version TEXT NOT NULL,         -- from manifest.json
  checksum TEXT NOT NULL,        -- SHA-256 of file content
  last_synced INTEGER            -- Unix ms timestamp
);

-- Chunk storage
CREATE TABLE chunks (
  id TEXT PRIMARY KEY,           -- UUID v4
  doc_id TEXT NOT NULL REFERENCES docs(id) ON DELETE CASCADE,
  topic TEXT NOT NULL,
  heading_path TEXT NOT NULL DEFAULT '',  -- e.g. "Finding Water > Rainwater"
  body TEXT NOT NULL,            -- raw chunk text
  chunk_index INTEGER NOT NULL,
  embedding BLOB                 -- NULL in Phase 1; ONNX embedding in Phase 2
);

-- Full-text search index (BM25 via FTS5)
CREATE VIRTUAL TABLE chunks_fts USING fts5(
  chunk_id UNINDEXED,
  topic,
  heading_path,
  body,
  tokenize = 'porter ascii'
);
```

---

## Storage Layout

```
/data/user/0/com.surviveai.survive_ai/files/
├── models/
│   └── gemma-2b-it-cpu-int4.bin            (~500MB, downloaded on first launch)
├── docs/
│   ├── manifest.json                       (last fetched manifest)
│   ├── war/
│   │   ├── ambush_response.md
│   │   └── checkpoint_crossing.md
│   ├── medical/
│   │   ├── tourniquet.md
│   │   └── shock_treatment.md
│   ├── jungle/
│   │   ├── water_finding.md
│   │   └── shelter_building.md
│   └── ...
└── survive_ai.db                           (~10MB, SQLite)
```

---

## First-Launch Routing (_EntryRouter)

```
App opens
    │
    ▼
SharedPreferences: disclaimer_accepted?
    │                       │
    ▼ (no)                  ▼ (yes)
DisclaimerScreen        HomeScreen (always)
    │                       │
    │ (accept)              ▼
    │                   DownloadService.findModelFile('gemma-2b-it-cpu-int4.bin')
    │                       │                    │
    │                       ▼ (missing)          ▼ (present)
    │                   HomeScreen shows     LlmService.loadModel()
    │                   download banner      (background, non-blocking)
    │                       │
    └───────────────────────┘
```

---

## Network Communication (WiFi-only, limited scope)

All network calls are read-only HTTP GETs to GitHub raw URLs. No auth, no POST, no user data sent.

| Call | When | URL Pattern |
|---|---|---|
| Fetch manifest | First launch + each app open with WiFi | `raw.githubusercontent.com/survive-ai/survive-ai-docs/main/manifest.json` |
| Download model | First launch, when model file absent | HuggingFace raw URL from manifest |
| Download doc | When doc SHA-256 differs from manifest | `raw.githubusercontent.com/survive-ai/survive-ai-docs/main/docs/{topic}/{file}.md` |

---

## Performance Targets

| Metric | Target | Measured on |
|---|---|---|
| Model load time | < 5s | Snapdragon 720G (mid-range) |
| First token latency | < 3s | Same |
| Token generation rate | >= 3 tokens/sec | Snapdragon 665 (low-end) |
| BM25 retrieval (4 chunks) | < 100ms | In-memory SQLite |
| App cold start to home | < 2s | After model is cached |

---

## Security & Privacy

- **No PII collected.** The app has no analytics, no crash reporting, no telemetry.
- **All data is local.** Chat history and survival docs exist only on the device.
- **Network calls are read-only** to public GitHub repos. No credentials, no auth tokens.
- **Checksums on every download.** SHA-256 verified before any file is written to disk.
- **APK distribution.** Users get the APK from GitHub Releases. The maintainer's signing key fingerprint is published in SECURITY.md so users can verify APK authenticity.
- **No location access.** The app never requests GPS permission (Phase 1–4). If GPS is added later (for map features), it will be optional and clearly explained.

---

## Phase 2: Semantic Search (Vector RAG) — Planned / Future

Phase 2 will add dense vector retrieval alongside BM25. This is not yet implemented.

**Additional components:**
- `all-MiniLM-L6-v2.onnx` (~22MB) — embedding model, run via `onnxruntime_flutter`
- `sqlite-vec` — SQLite extension for cosine similarity search
- `vec_chunks` virtual table with 384-dimensional float32 embeddings

**Hybrid retrieval (RRF — Reciprocal Rank Fusion):**

```
BM25 results:    [(chunk_a, rank=1), (chunk_b, rank=2), (chunk_c, rank=3)]
Vector results:  [(chunk_b, rank=1), (chunk_d, rank=2), (chunk_a, rank=3)]

RRF score = 1/(60+bm25_rank) + 1/(60+vector_rank)
chunk_a: 1/61 + 1/63 = 0.0164 + 0.0159 = 0.0323
chunk_b: 1/62 + 1/61 = 0.0161 + 0.0164 = 0.0325  ← wins
```

Enables semantic search: "I can't breathe" → finds "respiratory distress" docs even without keyword overlap.

The `embedding BLOB` column is already in the `chunks` table schema — Phase 2 integration only requires adding the ONNX inference and sqlite-vec extension.
