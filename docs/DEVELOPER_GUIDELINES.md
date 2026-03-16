# Developer Guidelines — Survive AI

This document covers everything a developer needs to contribute to the Survive AI codebase effectively. Read this before writing your first line of code.

---

## Getting Started

### Prerequisites

```bash
# Install Flutter (macOS via Homebrew)
brew install --cask flutter

# Verify installation
flutter doctor

# Clone the repo
git clone https://github.com/survive-ai/survive-ai.git
cd survive-ai

# Install dependencies
flutter pub get
```

### Running the App

You need an Android device or emulator running Android 7.0+ (API 24+).

```bash
# List connected devices
flutter devices

# Run in debug mode (hot reload enabled)
flutter run -d <device-id>

# Run in release mode (closer to production performance)
flutter run --release -d <device-id>
```

**Note on the LLM model:** In development, the model won't download automatically unless you have a working manifest URL. To test LLM features locally, manually copy `gemma-2b-it-cpu-int4.bin` to the device's `/sdcard/Download/` folder and modify `DownloadService.getExistingFile()` to locate it temporarily.

---

## Project Structure

```
lib/
├── models/        Pure data classes. No logic. No Flutter/Riverpod imports.
├── services/      Business logic. No UI. No Riverpod. Injectable via constructor.
├── providers/     Riverpod providers. Thin wrapper layer around services.
├── screens/       Full-page widgets. One file per screen.
├── widgets/       Reusable UI components. Stateless where possible.
└── utils/         Pure functions. No state. No Flutter imports.

docs/              Documentation directory.
test/              Unit + widget tests.
android/           Android-specific build config.
```

### File Index

| File | Purpose |
|---|---|
| `lib/main.dart` | App entry + `_EntryRouter` (first-launch routing logic) |
| `lib/models/chat_message.dart` | `ChatMessage` — role, content, timestamp |
| `lib/models/doc_chunk.dart` | `DocChunk` + `DocTopic` enum (6 categories) |
| `lib/models/doc_manifest.dart` | `DocManifest`, `ModelInfo`, `DocEntry` — manifest.json schema |
| `lib/services/llm_service.dart` | Wraps `flutter_gemma` (MediaPipe LLM Inference) — `loadModel()`, `chat()` stream |
| `lib/services/database_service.dart` | Owns SQLite schema; all chunk/doc CRUD |
| `lib/services/chunker_service.dart` | Markdown to 300-token chunks with 50-token overlap |
| `lib/services/rag_service.dart` | 3-way RRF retrieval: BM25 exact + BM25 expanded + dense (stubbed) |
| `lib/services/embedding_service.dart` | Stub embedding service — returns empty, dense leg falls back gracefully |
| `lib/services/sync_service.dart` | WiFi-gated GitHub sync with SHA-256 verification |
| `lib/services/download_service.dart` | Resumable HTTP downloads with SHA-256 verification |
| `lib/utils/query_expander.dart` | 130+ survival-domain synonym mappings for BM25 query expansion |
| `lib/providers/providers.dart` | All Riverpod providers + `llmReadyProvider` |
| `lib/screens/disclaimer_screen.dart` | First-launch safety acknowledgement |
| `lib/screens/setup_screen.dart` | Setup flow: WiFi check, manifest fetch, download, sync, load |
| `lib/screens/home_screen.dart` | Main screen with Chat/Topics tabs + Assess FAB |
| `lib/screens/chat_screen.dart` | RAG chat with streaming + trivial query filtering |
| `lib/screens/topic_browser_screen.dart` | 2x3 grid of topic cards |
| `lib/screens/doc_list_screen.dart` | List of docs within a topic |
| `lib/screens/doc_reader_screen.dart` | Full Markdown renderer + "Ask AI" button |
| `lib/screens/settings_screen.dart` | Storage info, sync controls |
| `lib/utils/prompt_builder.dart` | Instruction-last prompt template (optimized for 2B models) |
| `lib/widgets/message_bubble.dart` | Chat bubble with `BlinkingCursor` animation |
| `lib/widgets/sync_status_banner.dart` | Auto-check banner for available doc updates |

### Naming Conventions

| Type | Convention | Example |
|---|---|---|
| Files | `snake_case.dart` | `llm_service.dart` |
| Classes | `PascalCase` | `LlmService`, `DocChunk` |
| Private fields | `_camelCase` | `_db`, `_isLoaded` |
| Constants | `camelCase` | `const maxTokens = 300` |
| Providers | `camelCaseProvider` | `llmServiceProvider` |

---

## Architecture Rules

### Services

- **Constructor injection only.** Never use service locators, `GetIt`, or global singletons.
- **No Flutter imports.** Services don't know about widgets, `BuildContext`, or `MaterialApp`.
- **No Riverpod.** Riverpod providers wrap services; services don't use providers.
- **Implement `dispose()`.** Any service that holds resources (DB connection, isolate, stream) must implement a `dispose()` or `disposeAsync()` method.
- **Throw, don't swallow.** Services throw descriptive exceptions. Callers (providers/screens) handle errors.

```dart
// GOOD
class DatabaseService {
  DatabaseService(); // No dependencies? Fine. Has dependencies? Inject them.
  Future<void> dispose() async { await _db?.close(); }
}

// BAD
class DatabaseService {
  static final DatabaseService instance = DatabaseService._(); // No singletons
  DatabaseService._();
}
```

### Providers

- **Thin.** Providers only wire services together and expose state. No business logic.
- **`ref.onDispose` for cleanup.** Always register cleanup for services with resources.

```dart
final databaseServiceProvider = Provider<DatabaseService>((ref) {
  final service = DatabaseService();
  ref.onDispose(service.dispose);
  return service;
});
```

### Widgets/Screens

- **No business logic in widgets.** Widgets read from providers and dispatch events.
- **`ConsumerWidget` or `ConsumerStatefulWidget`** when reading Riverpod providers.
- **`StatelessWidget`** for pure display widgets with no state.
- **One screen = one file.** `home_screen.dart`, `chat_screen.dart`, etc.

---

## Code Quality

### Linting

This project uses `flutter_lints`. Zero lint warnings are required before merging.

```bash
flutter analyze
```

If you disagree with a lint rule for a specific case, use a targeted suppress comment — never disable the whole file:

```dart
// ignore: prefer_const_constructors — dynamic theme requires non-const
Theme(data: ThemeData(colorScheme: scheme), child: child)
```

### Testing

```bash
# Run all tests
flutter test

# Run a specific test file
flutter test test/services/chunker_service_test.dart
```

**What to test:**
- `services/` — Unit test all services with mock dependencies (use `mockito`)
- `services/chunker_service.dart` — Test chunk boundaries with known Markdown inputs
- `services/database_service.dart` — Integration test with in-memory SQLite (`sqflite_common_ffi`)
- `services/rag_service.dart` — Integration test with 3 seed docs loaded into in-memory DB
- `utils/prompt_builder.dart` — Unit test prompt string construction

**What NOT to test:**
- `LlmService` — inference is non-deterministic; test manually against benchmark prompts
- Widget tests for every screen — keep widget tests to critical flows (first launch, situation assessment)

### Test Structure

```dart
// test/services/chunker_service_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:survive_ai/services/chunker_service.dart';

void main() {
  group('ChunkerService', () {
    late ChunkerService chunker;

    setUp(() {
      chunker = const ChunkerService(maxTokens: 100, overlapTokens: 20);
    });

    test('splits at heading boundaries', () {
      final markdown = '# Title\nFirst section.\n\n## Subsection\nSecond section.';
      final chunks = chunker.chunk(markdown, 'doc1', 'general');
      expect(chunks.length, greaterThan(1));
      expect(chunks.first.headingPath, isNotEmpty);
    });
  });
}
```

---

## Adding a New Survival Doc

This section is for contributions to the **survive-ai-docs** repo (separate from this app repo).

### Step 1: Write the Doc

Follow this Markdown template:

```markdown
# Title (short, descriptive)

## Overview
1-2 sentences explaining what this guide covers and when to use it.

## When to Use
Specific situations where this knowledge applies.

## Materials Needed (if applicable)
- Item 1
- Item 2

## Procedure

### Step 1: First Action
Clear, specific instruction. No more than 3 sentences.

### Step 2: Next Action
...

## Warning Signs
Things that indicate the situation is worsening.

## Sources
- Source 1 (e.g., US Army Field Manual FM 21-76, Chapter X)
- Source 2
```

**Content standards:**
- Every factual claim must have a source in the Sources section
- No speculation — if uncertain, say "consult a medical professional when available"
- No specific medication dosages
- Write for someone who has never done this before

### Step 2: Place the File

```
survive-ai-docs/docs/{topic}/{descriptive_filename}.md
```

Topic must be one of: `war`, `medical`, `jungle`, `desert`, `urban`, `general`.

### Step 3: Update manifest.json

```json
{
  "id": "medical/tourniquet",
  "filename": "docs/medical/tourniquet.md",
  "topic": "medical",
  "title": "Tourniquet Application",
  "version": "1.0",
  "sha256": "<sha256 of file content>",
  "url": "https://raw.githubusercontent.com/survive-ai/survive-ai-docs/main/docs/medical/tourniquet.md"
}
```

Compute SHA-256: `shasum -a 256 docs/medical/tourniquet.md`

Increment the top-level `version` in manifest.json (format: `YYYYMMDD`).

### Step 4: Open a PR

- PR title: `docs: add {topic}/{filename}`
- PR description: explain what the doc covers, who it helps, and list your sources
- Requires 1 maintainer approval before merge

---

## Adding a New Topic Category

If you want to add a topic beyond the current 6 (war, medical, jungle, desert, urban, general):

1. Add the folder in `survive-ai-docs/docs/{new_topic}/`
2. Add at least 3 docs to the new topic before proposing it
3. Update `manifest.json` with the new docs
4. In the Flutter app:
   - Add `newTopic` to the `DocTopic` enum in [lib/models/doc_chunk.dart](../lib/models/doc_chunk.dart)
   - Add a tile to the `_topics` list in [lib/screens/topic_browser_screen.dart](../lib/screens/topic_browser_screen.dart)
5. Open PRs to both repos

---

## Upgrading the On-Device Model

The model download URL is controlled by `manifest.json` in the docs repo — not hardcoded in the app. To upgrade:

1. Download the new model binary (.bin) compatible with flutter_gemma (MediaPipe LLM Inference)
2. Compute its SHA-256: `shasum -a 256 gemma-2b-it-cpu-int4.bin`
3. Upload to a reliable public host (HuggingFace Hub recommended)
4. Update the `model` section in `manifest.json`:
   ```json
   {
     "model": {
       "name": "gemma-2b-it-cpu-int4.bin",
       "url": "https://huggingface.co/.../resolve/main/gemma-2b-it-cpu-int4.bin",
       "size_bytes": 1073741824,
       "sha256": "abc123..."
     }
   }
   ```
5. Users will be prompted to download the new model on their next WiFi sync

**Important:** Old model files are NOT automatically deleted. The new model is stored as `gemma-2b-it-cpu-int4.bin` (fixed filename), overwriting the old one after SHA-256 verification.

---

## Release Process

### Building a Release APK

```bash
# Build release APK (signed with debug key during development)
flutter build apk --release --target-platform android-arm64

# Output: build/app/outputs/flutter-apk/app-release.apk
```

For distribution, sign with a production keystore:

```bash
flutter build apk --release
# Signing configured in android/key.properties (not in git)
```

### Release Checklist

1. Bump `version` in `pubspec.yaml` (e.g., `1.1.0+2`)
2. Bump `version` in `manifest.json` (format: `YYYYMMDD`)
3. Run `flutter analyze` — zero warnings
4. Run `flutter test` — all passing
5. Build and test release APK on 2+ physical devices
6. Tag the release: `git tag v1.1.0`
7. Push tag: `git push origin v1.1.0`
8. GitHub Actions builds and attaches signed APK to GitHub Release
9. Publish release notes including SHA-256 of the APK

Users verify APK authenticity: `shasum -a 256 app-release.apk`

---

## CI/CD (GitHub Actions)

`.github/workflows/ci.yml` runs on every PR:

```yaml
steps:
  - flutter pub get
  - flutter analyze           # Zero warnings required
  - flutter test              # All tests must pass
  - flutter build apk --release   # APK must build successfully
```

`.github/workflows/release.yml` runs on tag push:

```yaml
steps:
  - All CI steps above
  - Sign APK with production keystore (from GitHub Secrets)
  - Compute SHA-256 of signed APK
  - Create GitHub Release with APK attachment and SHA-256 in release body
```

---

## Common Development Pitfalls

**The model won't load on device:**
- Check that `gemma-2b-it-cpu-int4.bin` is in `/data/user/0/com.surviveai.survive_ai/files/models/`
- Verify the device has at least 1.5GB free RAM
- Check `adb logcat | grep "survive_ai\|flutter_gemma\|mediapipe"` for crash output

**FTS5 search returns no results:**
- Check that chunks were inserted into `chunks_fts` (not just `chunks`)
- FTS5 MATCH syntax is strict — avoid special characters in queries
- The porter stemmer normalizes words — "running" matches "run"

**Riverpod provider causes infinite rebuild:**
- Avoid `ref.watch` inside loops — use `ref.read` for one-shot reads in button callbacks

**Flutter analyze fails after adding a new dependency:**
- Run `flutter pub get` first
- Check if the new dep introduces a lint suppression conflict

**SHA-256 mismatch on doc download:**
- Verify the SHA-256 in manifest.json was computed from the exact file bytes (UTF-8 encoded)
- Make sure there are no trailing newline differences between platforms
- Use `shasum -a 256` on macOS, `sha256sum` on Linux — both produce the same output for the same bytes

---

## Contact & Governance

- **Maintainer:** @samarthsaraswat
- **Doc review:** All PRs to survive-ai-docs require maintainer approval. Medical content requires SME review.
- **Bug reports:** File issues at `github.com/survive-ai/survive-ai/issues`
- **Security vulnerabilities:** Email directly (do not open a public issue)

This is a humanitarian project. We welcome contributions from anyone with relevant knowledge — developers, survival experts, medics, translators, and field workers.
