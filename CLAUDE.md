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

## Design Principle: Speed Over Sophistication

This app runs on 4GB Android devices in survival emergencies. Every design decision prioritizes fast, correct answers over architectural elegance:
- **2B model** over larger models (first token in <3s vs 10+s)
- **BM25 + query expansion** over neural embeddings (zero extra memory vs 200MB+ OOM)
- **Instruction-last prompts** over long system prompts (2B models forget early instructions)
- **CPU backend** over GPU (pageable RAM vs shared memory OOM on 4GB devices)

## Key Patterns

**RAG pipeline (2-leg BM25 + RRF):** Query → (1) BM25 exact match via FTS5 + (2) BM25 on synonym-expanded query via QueryExpander → Reciprocal Rank Fusion merge (K=60) → top 4 chunks → injected as reference material in prompt → Gemma generates response. Trivial queries (< 3 words) skip RAG entirely to avoid confusing the model with irrelevant context.

**Query expansion:** `QueryExpander` in `lib/utils/query_expander.dart` maps 130+ survival-domain terms to synonyms/related terms (e.g. "bleeding" → "hemorrhage wound tourniquet"). This bridges vocabulary gaps between user language and medical/survival terminology without requiring a neural embedding model. Expansion capped at 8 terms to avoid query dilution.

**Prompt structure (optimized for 2B):** Prompt is built in `lib/utils/prompt_builder.dart` as plain text (no turn markers — flutter_gemma adds those automatically). Layout is instruction-last: (1) RAG reference material first, (2) conversation history, (3) short instruction (~60 tokens) RIGHT BEFORE the question, (4) question last. This structure ensures the 2B model's attention is focused on the instruction when it starts generating.

**LLM isolation:** All `flutter_gemma` calls go through `LlmService` only. UI never touches the model directly. `flutter_gemma` manages its own background isolate for inference.

**Memory safety:** KV cache is recycled between turns — old session is nulled and closed before the new one allocates. Gemma runs on CPU backend to avoid shared GPU/RAM exhaustion on 4 GB devices. Streaming UI updates are batched at 50ms intervals to reduce GC pressure. Stream errors caught via `.handleError()`.

**Offline-first:** No cloud calls at runtime. WiFi-gated sync fetches a `manifest.json` from GitHub, downloads changed Markdown docs, re-indexes via chunker → FTS5.

**Embedding service (stub):** `EmbeddingService` exists but always returns empty results. `RagService` has full 3-way RRF retrieval logic (BM25 exact + BM25 expanded + dense) but the dense leg returns empty since embeddings are disabled. This is intentional — any additional ML runtime alongside Gemma causes OOM on 4 GB devices. The infrastructure is ready for when device capabilities improve.

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
- `lib/utils/prompt_builder.dart` — Instruction-last prompt template for 2B model
- `lib/utils/query_expander.dart` — Domain-specific synonym expansion (130+ terms)
- `lib/screens/` — one file per full-page route
- `lib/widgets/` — reusable UI components (`MessageBubble`, `SyncStatusBanner`)

## Model Config

- Gemma 2B IT, INT4 quantized, CPU backend via `flutter_gemma` (MediaPipe LLM Inference)
- Model file: `gemma-2b-it-cpu-int4.bin` (~500 MB)
- Sampling: temp=0.7, top_k=40
- Max output tokens: 512
- Token budget: 4096 context − 512 output − 84 safety = 3500 max prompt tokens
- Android: `minSdk 24`, `abiFilters: ["arm64-v8a"]`
