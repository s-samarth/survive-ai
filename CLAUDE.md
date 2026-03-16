# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

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

**No business logic in widgets.** Widgets read from providers and dispatch to services only.

## Key Patterns

**RAG pipeline (BM25 via FTS5):** Query → FTS5 BM25 retrieval (top 4 chunks, field-weighted: heading 2×, body 1.5×) → context injected between `[CONTEXT]` tags in system prompt → Gemma generates response. Chunking: ~300 tokens, 50-token overlap, split at headings first then paragraphs.

**Prompt template:** The chat prompt is centralized in `lib/utils/prompt_builder.dart` using `<start_of_turn>role\n...<end_of_turn>` format. Never hardcode prompts in services.

**LLM isolation:** All `flutter_gemma` calls go through `LlmService` only. UI never touches the model directly. `flutter_gemma` manages its own background isolate for inference.

**Memory safety:** KV cache is recycled between turns — old session is nulled and closed before the new one allocates. Gemma runs on CPU backend to avoid shared GPU/RAM exhaustion on 4 GB devices. Streaming UI updates are batched at 50ms intervals to reduce GC pressure.

**Offline-first:** No cloud calls at runtime. WiFi-gated sync fetches a `manifest.json` from GitHub, downloads changed Markdown docs, re-indexes via chunker → FTS5.

**Embedding service (stub):** `EmbeddingService` exists but always returns empty results. `RagService` has full hybrid BM25+dense retrieval logic (RRF merge) but falls back to pure BM25 since embeddings are disabled. This is intentional — any additional ML runtime alongside Gemma causes OOM on 4 GB devices.

**Database schema:** `docs` (registry + sync state) → `chunks` + `chunks_fts` (FTS5 virtual table for BM25). The `chunks` table has an `embedding BLOB` column reserved for future dense retrieval.

**Zero-Wait RAG:** On first install, survival guides bundled as Flutter assets are seeded into the database immediately so the app has expert knowledge before any network sync.

## State Management (Riverpod 2.x)

- Services are constructor-injectable `Provider<T>` singletons; no service locators
- Disposal via `ref.onDispose()`
- Key state providers: `llmReadyProvider`, `llmErrorProvider`, `modelDownloadProgressProvider`
- Tests use `sqflite_common_ffi` for in-memory SQLite; mock services with `mockito`

## File Layout

- `lib/services/` — all business logic (no Flutter imports where avoidable)
- `lib/models/` — pure data classes (`ChatMessage`, `DocChunk`, `DocManifest`)
- `lib/providers/providers.dart` — Riverpod wiring, singleton lifecycle
- `lib/utils/prompt_builder.dart` — LLM prompt template
- `lib/screens/` — one file per full-page route
- `lib/widgets/` — reusable UI components (`MessageBubble`, `SyncStatusBanner`)

## Model Config

- Gemma 2B IT, INT4 quantized, CPU backend via `flutter_gemma` (MediaPipe LLM Inference)
- Model file: `gemma-2b-it-cpu-int4.bin` (~500 MB)
- Sampling: temp=0.7, top_k=40
- Max output tokens: 512
- Android: `minSdk 24`, `abiFilters: ["arm64-v8a"]`
