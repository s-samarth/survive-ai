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
flutter test test/services/rag_service_test.dart

# Code generation (after modifying Riverpod providers with @riverpod annotation)
flutter pub run build_runner build --delete-conflicting-outputs

# Build release APK (sideloaded, not Play Store)
flutter build apk --release --target-platform android-arm,android-arm64
```

## Architecture

```
UI Layer (Screens/Widgets)
        ↓ reads/watches providers
Providers (Riverpod singletons)
        ↓ inject services
Services (business logic)
        ↓
DatabaseService (SQLite) + llama_cpp_dart FFI + HTTP
        ↓
/files/models/model.gguf  |  /files/docs/{topic}/*.md  |  survive_ai.db
```

**No business logic in widgets.** Widgets read from providers and dispatch to services only.

## Key Patterns

**Intent classification → agentic routing:** Every chat turn runs a single-word LLM call (`CHAT | ASSESS | GUIDE`) before the main response. The result drives navigation: `ASSESS` → `SituationScreen`, `GUIDE` → `StepGuideScreen`, `CHAT` stays in chat.

**RAG pipeline (BM25 only):** Query → FTS5 BM25 retrieval (top 4 chunks) → context injected between `[CONTEXT]` tags in system prompt → Gemma 3 generates response. Chunking: ~300 tokens, 50-token overlap, split at headings first then paragraphs.

**Prompt templates:** All 4 Gemma 3 prompts are centralized in `lib/utils/prompt_builder.dart` using `<start_of_turn>role\n...<end_of_turn>` format. Never hardcode prompts in services.

**LLM isolation:** All `llama_cpp_dart` FFI calls go through `LlmService` only. UI never touches the FFI directly. Inference runs in a background isolate via `LlamaParent`.

**Offline-first:** No cloud calls at runtime. WiFi-gated sync fetches a `manifest.json` from GitHub, downloads changed Markdown docs, re-indexes via chunker → FTS5. Downloads are resumable with SHA-256 verification.

**Database schema:** `docs` (registry + sync state) → `chunks` + `chunks_fts` (FTS5 virtual table for BM25) → `action_plans` + `action_steps` (persistent situation checklists).

**Assessment is deterministic:** `SituationAssessor` uses 5 hardcoded questions (no LLM). LLM only runs on the answers to extract a `Situation` JSON and generate an `ActionPlan`.

## State Management (Riverpod 2.x)

- Services are constructor-injectable `Provider<T>` singletons; no service locators
- Disposal via `ref.onDispose()`
- Key state providers: `llmReadyProvider`, `modelDownloadProgressProvider`
- Tests use `sqflite_common_ffi` for in-memory SQLite; mock services with `mockito`

## File Layout

- `lib/services/` — all business logic (no Flutter imports where avoidable)
- `lib/models/` — pure data classes (no logic, no Flutter imports)
- `lib/providers/providers.dart` — Riverpod wiring, singleton lifecycle
- `lib/utils/prompt_builder.dart` — all LLM prompt templates
- `lib/screens/` — one file per full-page route
- `lib/widgets/` — reusable UI components

## Model Config

- Gemma 3 1B GGUF, CPU-only, 4 threads, 4096-token context, 512-token max output
- Sampling: temp=0.7, top_k=40, top_p=0.95
- Android: `minSdk 24`, `abiFilters: ["arm64-v8a", "armeabi-v7a"]`
