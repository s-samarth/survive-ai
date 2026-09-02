# System Design — Survive AI

## Overview

Survive AI is a fully offline Android application that runs an AI survival assistant on a mid-range Android phone — 6 GB RAM minimum, 8 GB recommended. After a one-time WiFi setup, all computation runs locally — there is no backend server, no cloud database, no API calls during normal operation.

Every architectural choice is driven by one constraint: **this must work on a 6 GB Android phone, offline, fast enough to be useful during the emergency itself.**

---

## Design Philosophy: Why Simple Beats Sophisticated

Cloud-based AI systems optimize for accuracy. They can use massive models, ensemble retrievers, multi-stage pipelines, and expensive rerankers. Survive AI cannot use any of that. The constraints are:

1. **6 GB device RAM** — Android takes ~1.8 GB and the LLM ~1.6 GB, leaving roughly 2.5 GB for everything else
2. **No network at runtime** — the app must function as if the internet will never come back
3. **Speed over sophistication** — an answer in seconds, not tens of seconds
4. **Nothing expensive on the query path** — anything that can be precomputed at build time must be

These constraints lead to decisions that would look "wrong" in a cloud system but are exactly right for this use case:

| Cloud approach | Our approach | Why |
|---|---|---|
| Embed the corpus on the device | Embed it offline; ship the vectors | The corpus is identical everywhere and never changes; only the query needs encoding |
| Rerank with a cross-encoder | Weighted RRF over three legs | Recall@20 is 98%; a reranker is 100 MB+ and a second forward pass for 8 points of ordering |
| Long system prompt (~1000 tokens) | Short instruction (~60 tokens) at end of prompt | 2B models forget instructions at the top; attention is strongest near generation point |
| GPU inference for speed | CPU inference only | GPU uses shared memory on Android; CPU uses pageable RAM that the OS can manage |
| Persistent sessions with KV cache | Fresh session every turn, KV cache recycled | Prevents memory accumulation; keeps RAM usage flat regardless of conversation length |
| Complex reranking pipeline | Reciprocal Rank Fusion (RRF) | Single-pass merge with no additional model; gracefully degrades if signals are missing |

---

## High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│              SURVIVE AI — 6 GB ANDROID DEVICE (minimum)              │
│                                                                      │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │                     UI Layer (Flutter)                        │   │
│  │  DisclaimerScreen  SetupScreen  HomeScreen  ChatScreen        │   │
│  │  TopicBrowserScreen  GuideReaderScreen  SettingsScreen        │   │
│  └──────────────────────────┬───────────────────────────────────┘   │
│                              │ Riverpod providers                    │
│  ┌──────────────────────────▼───────────────────────────────────┐   │
│  │                    Service Layer (Dart)                        │   │
│  │                                                               │   │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐   │   │
│  │            ┌──────────────────────┐                         │   │
│  │            │   ChatTurnService    │  one turn, end to end   │   │
│  │            └───────────┬──────────┘                         │   │
│  │  ┌──────────────┐  ┌───┴──────────┐  ┌──────────────────┐   │   │
│  │  │  LlmService  │  │  RagService  │  │   SyncService    │   │   │
│  │  │ Gemma 2B IT  │  │ 3-leg + RRF  │  │  WiFi-gated      │   │   │
│  │  │ CPU backend  │  │ (weighted)   │  │  GitHub sync     │   │   │
│  │  └──────┬───────┘  └──────┬───────┘  └────────┬─────────┘   │   │
│  │         │                 │                    │             │   │
│  │  ┌──────┴─────┐  ┌───────┴────────┐  ┌────────┴─────────┐   │   │
│  │  │PromptBuild │  │ QueryExpander  │  │ OnnxEmbedding    │   │   │
│  │  │(instr-last)│  │ + Hinglish     │  │ EmbeddingGemma   │   │   │
│  │  │QueryRouter │  │ Transliteration│  │ + GemmaTokenizer │   │   │
│  │  │AnswerGuard │  │                │  │                  │   │   │
│  │  └────────────┘  └────────────────┘  └──────────────────┘   │   │
│  │         │                 │                    │             │   │
│  │  ┌──────┴─────────────────┴────────────────────┴──────────┐ │   │
│  │  │              DatabaseService (SQLite)                    │ │   │
│  │  │  chunks (+ embedding) | chunks_fts (FTS5) | citations   │ │   │
│  │  └──────────────────────────────────────────────────────────┘ │   │
│  │                                                               │   │
│  │  ┌──────────────────┐  ┌──────────────────┐                  │   │
│  │  │ IndexLoaderSvc   │  │  DownloadService │                  │   │
│  │  │ (offline-built)  │  │ (resumable HTTP) │                  │   │
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
// CPU backend only — GPU draws from the same shared pool and the OS cannot
// KV cache recycled every turn — old session nulled BEFORE new one allocates.
Future<void> loadModel(String modelPath);          // Re-activate model each launch
Stream<String> chat({required String prompt});      // Creates session, streams tokens
Future<void> disposeAsync();                       // Closes session and model
```

### RagService

```dart
// 3-way Reciprocal Rank Fusion retrieval:
//   Leg 1: BM25 on the original query          weight 1.0
//   Leg 2: BM25 on the expanded query          weight 0.7
//   Leg 3: cosine over shipped passage vectors weight 1.5
//          (skipped entirely for romanised Hindi)
Future<List<DocChunk>> retrieve(String query, {int topK = 4, String? topicFilter});

// The dense leg alone — the one ranking fully determined by the vectors, and
// therefore the one a test can assert identical to the Python lab.
Future<List<String>> denseCandidates(Float32List queryVec, {String? topicFilter});

// Top embedding cosine, or null when this build has no encoder. Null means
// *unknown*, which is not zero: a zero was measured and justifies declining,
// an unknown must not, because refusing on absent evidence turns away
// emergencies on a device that never downloaded the encoder.
Future<double?> confidence(String query, {String? topicFilter});
```

### QueryExpander

```dart
// Pure Dart synonym expansion — zero memory, sub-millisecond.
// Maps ~170 survival-domain, romanised-Hindi and India-specific triggers.
// Example: "bleeding" → "bleeding hemorrhage wound blood tourniquet pressure dressing bandage"
// Romanised Hindi: "khoon" → blood, "aag" → fire, "saanp" → snake, "baadh" → flood
// India-specific: LPG, lathi, nala, ORS, ASV
// Includes simple stemming (strips -ing, -ed, -ly, -s) for broader matching.
// Capped at 10 additions — beyond that the query dilutes.
// Expansion capped at 8 terms to avoid query dilution.
static String expand(String query);
```

### PromptBuilder

```dart
// Instruction-last prompt structure optimized for 2B models.
// Layout: (1) RAG reference material, (2) history, (3) instruction, (4) question.
// Returns PLAIN TEXT — flutter_gemma adds turn markers automatically.
// Token budget: 1452 (2048 context − 512 output − 84 safety), derived from
// kMaxPromptTokens so the two cannot drift.
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
    ├─── Leg 3: Dense cosine ────────────────────────────────────┤
    │    GemmaTokenizer encodes the query (~10 tokens)            │
    │    EmbeddingGemma-300m under ONNX Runtime → 768-d vector    │
    │    cosine against the 201 shipped passage vectors           │
    │    (skipped entirely if the query is romanised Hindi,       │
    │     or if the encoder was never downloaded)                 │
    │                                                             │
    ▼                                                             │
    Weighted Reciprocal Rank Fusion (K=60)                       │
    score(chunk) = Σ_legs  weight / (rank_in_leg + 60)          │
    weights: literal 1.0, expanded 0.7, dense 1.5                │
    │                                                             │
    ▼                                                             │
    Top 5 passages, greedily fitted into the token budget        │
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

### Closing the Vocabulary Gap

The gap between what a user types and what the guides say is the core retrieval
challenge:

| User says | Guides say | BM25 alone? |
|---|---|---|
| "I'm bleeding" | "haemorrhage control" | miss |
| "khoon nikal raha hai" | "severe bleeding" | miss |
| "can't breathe" | "airway obstruction" | miss |
| "hot dry skin, confused" | "heat stroke" | miss |

Two mechanisms close it, and they cover different failures.

**Query expansion** handles what can be anticipated: a hand-built dictionary of
survival synonyms, romanised Hindi, and India-specific nouns, run as a second
BM25 leg. Pure Dart, sub-millisecond, zero memory.

**The dense leg** handles what cannot: paraphrase, and symptoms described
rather than named. EmbeddingGemma-300m encodes the query on the device; the
corpus vectors are precomputed and shipped, so no document is ever embedded on
a phone.

Measured contribution: keyword-only reaches Recall@5 81.5%, hybrid 89.7%. Full
detail in [RETRIEVAL.md](RETRIEVAL.md) and
[ON_DEVICE_EMBEDDINGS.md](ON_DEVICE_EMBEDDINGS.md).

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
| History capped at 4 turns; questions 400 chars, answers 220 | A question is short and load-bearing; an answer is long and the model can restate it. History fills **newest-first** — filling oldest-first kept the oldest turns and dropped the newest, exactly backwards for a follow-up |
| Token budget with priority allocation | Instruction + question reserved first, then context, then history — ensures critical content always fits |
| flutter_gemma handles turn markers | Prompt returned as plain text — no risk of double-wrapping `<start_of_turn>` tags |

---

## Memory Safety Architecture

### The Challenge

On a 6 GB Android device with Gemma 2B IT loaded. Budgeted, not yet measured on
hardware.

| Component | RAM |
|---|---|
| Android OS + system services | ~1.8 GB |
| Gemma 2B IT (INT4, mmap'd) | ~1.6 GB |
| KV attention cache (2048-token context) | ~150 MB |
| Flutter framework + app heap | ~200 MB |
| EmbeddingGemma q4f16 (mmap'd, reclaimable) | ~175 MB |
| Packed tokenizer tables | ~18 MB |
| SQLite + FTS5 index | ~20 MB |
| **Total** | **~4.0 GB** |
| **Headroom on 6 GB** | **~2 GB** |

### Protections

**CPU backend (not GPU):** On Android, GPU inference draws from the same shared
memory pool, and the OS cannot reclaim it under pressure. CPU inference uses
pageable RAM that Android can swap or reclaim — a pressure relief valve.

**Memory-mapped encoder weights:** EmbeddingGemma's weights live in a
`.onnx_data` sidecar that ONNX Runtime memory-maps, so those 175 MB are
file-backed and evictable rather than anonymous. A single self-contained
`.onnx` would be simpler to ship and would hold the same bytes for the life of
the process.

**KV cache recycling:** Each inference turn creates a fresh session. The previous session is nulled and closed BEFORE the new one allocates. Without this, both sessions exist in memory simultaneously — a 400MB spike that triggers OOM on the second+ turn.

```dart
final prev = _session;
_session = null;        // null reference FIRST
await prev?.close();    // THEN close (free memory)
_session = await _model!.createSession(...);  // THEN allocate
```

**50ms UI batching:** Without batching, every streamed token triggers a `setState()` call and a new String allocation. Over a 512-token response, that's 512 GC cycles. Batching at 50ms reduces this to ~25 updates, cutting GC pressure by ~20x.

**Stream error handling:** `getResponseAsync()` reports errors via `StreamController.addError()`. Without explicit `.handleError()`, unhandled stream errors crash the app. We convert them to catchable `StateError` exceptions shown in the UI.

**Prompt budget system:** The instruction and question are reserved first, a
history reserve is held back, and reference passages fill what remains greedily
— always keeping at least one. The earlier all-or-nothing form dropped the
*entire* reference block when it did not fit, so the model answered from
pretraining with nothing retrieved. That failure was silent and invisible to
every metric that did not inspect the prompt itself.

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
  id TEXT PRIMARY KEY,           -- content-derived, assigned offline
  doc_id TEXT NOT NULL REFERENCES docs(id) ON DELETE CASCADE,
  topic TEXT NOT NULL,
  heading_path TEXT NOT NULL DEFAULT '',
  body TEXT NOT NULL,
  chunk_index INTEGER NOT NULL,
  embedding BLOB                 -- the passage vector that shipped with the index
);

-- External-content FTS5: stores only the inverted index and reads column
-- values back from `chunks`, halving the database. Its columns are exactly
-- topic / heading_path / body — there is NO chunk_id column, and queries
-- reach the id by joining on rowid.
CREATE VIRTUAL TABLE chunks_fts USING fts5(
  topic,
  heading_path,
  body,
  content = 'chunks',
  content_rowid = 'rowid',
  tokenize = 'porter ascii'
);

-- The paragraphs a passage was built from: what a citation points at.
CREATE TABLE citations (
  id TEXT PRIMARY KEY,
  chunk_id TEXT NOT NULL,        -- the passage this paragraph belongs to
  doc_id TEXT NOT NULL,
  line_start INTEGER NOT NULL,   -- span in the source markdown
  line_end INTEGER NOT NULL,
  is_prohibition INTEGER NOT NULL DEFAULT 0
);
```

**AFTER INSERT / DELETE / UPDATE triggers on `chunks` are the only writer to
`chunks_fts`.** Two rules follow, and breaking either is silent:

- **Never write to `chunks_fts` directly.** Code that did named a `chunk_id`
  column this table does not have, so every batch raised and keyword search
  returned nothing on the device — while a test suite that rebuilt the schema
  by hand stayed green.
- **Never use `ConflictAlgorithm.replace` on `chunks`.** SQLite's REPLACE skips
  DELETE triggers, orphaning the old index row under its old rowid and
  appending a second one. The index then grows by a full copy of the corpus on
  every re-ingest, quietly skewing BM25.

---

## Performance Targets

| Metric | Target | Why it matters |
|---|---|---|
| First token latency | < 3s | Currently **6.1 s on a laptop** — the main open performance problem |
| Retrieval (3 legs + fusion) | < 100ms | RAG overhead must be imperceptible |
| Query encoding (dense leg) | < 100ms | One forward pass over ~10 tokens |
| Token generation rate | >= 3 tok/sec | Measured 5.1 tok/s on a laptop |
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

## Dense Retrieval — Shipped

The third RRF leg is live. EmbeddingGemma-300m (`q4f16` ONNX, 175 MB) encodes
the query on the device; the 201 passage vectors are computed offline and ship
as a 603 KB file, so no document is ever embedded on a phone.

It is an **optional download**, offered in Settings rather than during setup.
Without it `EmbeddingService.isEnabled` is false, `RagService` skips the leg,
and the app answers on its two lexical legs — a degradation, never an outage.

Worth reading before touching any of it:
[ON_DEVICE_EMBEDDINGS.md](ON_DEVICE_EMBEDDINGS.md) covers the artifact set, the
packed tokenizer, and two silent traps (a vector cache keyed without the
backend; a graph that does not fully mask padding) that each produced numbers
no device could reproduce.
