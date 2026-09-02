# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

## Commands

```bash
# Get dependencies
flutter pub get

# Run analysis (zero warnings enforced)
flutter analyze

# Run tests
flutter test

# Run a single test file
flutter test test/services/chunker_service_test.dart

# Code generation (after modifying Riverpod providers with @riverpod annotation)
flutter pub run build_runner build --delete-conflicting-outputs

# Build release APK (sideloaded, not Play Store)
flutter build apk --release --target-platform android-arm64
```

## Architecture

```
UI Layer (Screens/Widgets)
        ↓ reads/watches providers
Providers (Riverpod singletons)
        ↓ inject services
Services (business logic)
        ↓
DatabaseService (SQLite) + flutter_gemma (MediaPipe LLM) + HTTP
        ↓
/files/models/gemma-2b-it-cpu-int4.bin  |  /files/docs/{topic}/*.md  |  survive_ai.db
```

**Scope: India.** The corpus, the emergency numbers, the query-expansion
vocabulary (including romanised Hindi), and the topic taxonomy are all
India-specific by design. Do not genericise them.

**No business logic in widgets.** Widgets read from providers and dispatch to services only.

## Design Principle: Speed Over Sophistication

This app runs on 4GB Android devices in survival emergencies. Every design decision prioritizes fast, correct answers over architectural elegance:
- **2B model** over larger models (first token in <3s vs 10+s)
- **BM25 + query expansion** over neural embeddings (zero extra memory vs 200MB+ OOM)
- **Instruction-last prompts** over long system prompts (2B models forget early instructions)
- **CPU backend** over GPU (pageable RAM vs shared memory OOM on 4GB devices)

## Key Patterns

**RAG pipeline (2-leg BM25 + RRF):** Query → (1) BM25 exact match via FTS5 + (2) BM25 on synonym-expanded query via QueryExpander → Reciprocal Rank Fusion merge (K=60) → top 4 chunks → injected as reference material in prompt → Gemma generates response. Only pure greetings skip RAG (see `_smallTalk` in `chat_screen.dart`) — a word-count threshold wrongly excluded two-word emergencies like "chest pain".

**FTS5 query construction is not optional.** FTS5's implicit operator between
bare terms is **AND**, so passing a raw sentence to `MATCH` requires every word
to appear in one chunk and returns nothing for real questions. All queries go
through `DatabaseService.buildMatchExpression`, which strips stopwords, quotes
each term (so FTS5 keywords like `OR`/`NEAR` are not parsed as syntax), and
OR-joins them. There is a regression test; do not bypass this helper.

**`chunks_fts` is an external-content FTS5 table maintained by triggers.** Write
only to `chunks`. Never insert into `chunks_fts` directly, and never use
`ConflictAlgorithm.replace` on `chunks` — SQLite's REPLACE skips DELETE
triggers, orphaning the old index row and appending a duplicate.

**Query expansion:** `QueryExpander` (`lib/utils/query_expander.dart`) with its vocabulary in `lib/utils/expansion_terms.dart` maps survival-domain terms, romanised Hindi ("khoon" → blood, "aag" → fire, "saanp" → snake), and India-specific nouns (LPG, lathi, nala, ORS, ASV) onto the English terms the corpus uses. Without the Hinglish entries, a large share of real Indian queries retrieve nothing. Expansion is capped at 10 terms to avoid query dilution.

**Prompt structure (optimized for 2B):** Prompt is built in `lib/utils/prompt_builder.dart` as plain text (no turn markers — flutter_gemma adds those automatically). Layout is instruction-last: (1) RAG reference material first, (2) conversation history, (3) short instruction (~60 tokens) RIGHT BEFORE the question, (4) question last. This structure ensures the 2B model's attention is focused on the instruction when it starts generating.

**LLM isolation:** All `flutter_gemma` calls go through `LlmService` only. UI never touches the model directly. `flutter_gemma` manages its own background isolate for inference.

**Memory safety:** KV cache is recycled between turns — old session is nulled and closed before the new one allocates. Gemma runs on CPU backend to avoid shared GPU/RAM exhaustion on 4 GB devices. Streaming UI updates are batched at 50ms intervals to reduce GC pressure. Stream errors caught via `.handleError()`.

**Offline-first:** No cloud calls at runtime. WiFi-gated sync fetches a `manifest.json` from GitHub, downloads changed Markdown docs, re-indexes via chunker → FTS5.

**Embedding service (disabled):** `EmbeddingService.isEnabled` is false, so `RagService` skips the dense leg entirely — no vector is allocated on the query path. Intentional: a second native ML runtime alongside Gemma does not fit the memory budget on a 4-6 GB device. `EmbeddingGemma-300m` runs in under 200 MB and is the candidate for enabling it; the plumbing is a one-flag change.

**Database schema:** `docs` (registry + sync state) → `chunks` + `chunks_fts` (FTS5 virtual table for BM25). The `chunks` table has an `embedding BLOB` column reserved for future dense retrieval.

**Zero-Wait RAG:** `SyncService.seedFromAssets()` runs from `main.dart` on **every** launch, independent of the model. It is idempotent (skips topics already at `bundledVersion`). Do not move it back behind the model-download flow — a sideloaded or already-present model then leaves the corpus permanently empty. Bump `SyncService.bundledVersion` whenever the shipped Markdown changes.

## State Management (Riverpod 2.x)

- Services are constructor-injectable `Provider<T>` singletons; no service locators
- Disposal via `ref.onDispose()`
- Key state providers: `llmReadyProvider`, `llmErrorProvider`, `modelDownloadProgressProvider`
- Tests use `sqflite_common_ffi` for in-memory SQLite; mock services with `mockito`

## File Layout

- `lib/services/` — all business logic (no Flutter imports where avoidable)
- `lib/models/` — pure data classes (`ChatMessage`, `DocChunk`, `DocManifest`)
- `lib/providers/providers.dart` — Riverpod wiring, singleton lifecycle
- `lib/models/doc_topic.dart` — the 18 India situations; single source of truth for asset paths, DB topic keys, and RAG filters
- `lib/utils/prompt_builder.dart` — Instruction-last prompt template for 2B model
- `lib/utils/query_expander.dart` + `expansion_terms.dart` — synonym and Hinglish expansion
- `lib/screens/` — one file per full-page route
- `lib/widgets/` — reusable UI components (`MessageBubble`, `SyncStatusBanner`)

## Model Config

- Gemma 2B IT, INT4 quantized, CPU backend via `flutter_gemma` (MediaPipe LLM Inference)
- Model file: `gemma-2b-it-cpu-int4.bin` (~500 MB)
- Sampling: temp=0.7, top_k=40
- **`maxTokens` in flutter_gemma is the FULL context window (prompt + reply), not an output cap.** It is `kContextTokens` in `llm_service.dart`.
- Token budget: `kMaxPromptTokens` = 2048 context − 512 reserved output − 84 safety = 1452 prompt tokens. `PromptBuilder` derives its budget from this constant so the two cannot drift.
- Android: `minSdk 24`, `abiFilters: ["arm64-v8a"]`, `largeHeap="true"`

## Content and model updates

Both are driven by `manifest.json`, not by an APK release:
- Manifest URL: `kManifestUrl` in `sync_service.dart`, overridable with `--dart-define=SURVIVE_AI_MANIFEST_URL=...`
- The manifest's `model` entry (url, size_bytes, sha256, version) wins over the compiled-in fallbacks in `setup_screen.dart`, so the model can be swapped without shipping a build.
- Model downloads are resumable and verified: size check, then streaming SHA-256. A partial download is only resumed when its sidecar `.part.json` proves it came from the same URL and expected content.
