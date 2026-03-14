# User Flows

This document describes every major path through the Survive AI app, from first launch through ongoing offline use. All flows are implemented in the current codebase.

---

## Flow 1: First Launch (WiFi Required)

The only moment in the app's lifecycle that requires internet.

```
┌──────────────────────────────────────────────────────────────────────┐
│                         FIRST LAUNCH                                 │
│                                                                      │
│  Open App                                                            │
│      │                                                               │
│      ▼                                                               │
│  _EntryRouter checks SharedPreferences                               │
│  disclaimer_accepted == false?                                       │
│      │                                                               │
│      ▼                                                               │
│  DisclaimerScreen                                                    │
│  "This app provides general survival guidance only.                  │
│   Always seek professional medical/emergency help when available."   │
│      │                                                               │
│  [I Understand] button                                               │
│      │                                                               │
│      ▼                                                               │
│  SetupScreen: Check connectivity                                     │
│      │                          │                                    │
│      ▼ (WiFi available)         ▼ (No internet)                     │
│  Fetch manifest.json        Show WiFi prompt:                        │
│  from GitHub                "Connect to WiFi to download            │
│      │                       the AI model (~500MB)"                 │
│      ▼                              │                                │
│  Download model.gguf           [Retry] button                        │
│  (progress bar, resumable)          │ (user connects)               │
│      │                             └──► (back to connectivity check)│
│      ▼                                                               │
│  SHA-256 checksum verified                                           │
│      │                                                               │
│      ▼                                                               │
│  Download survival docs (initial set)                                │
│  Index docs into local SQLite                                        │
│      │                                                               │
│      ▼                                                               │
│  Load Gemma 3 1B model                                               │
│      │                                                               │
│      ▼                                                               │
│  HOME SCREEN  ← User is now fully offline capable                   │
└──────────────────────────────────────────────────────────────────────┘
```

**Screen:** `DisclaimerScreen` → `SetupScreen` → `HomeScreen`

**Key behavior:**
- If the download is interrupted, it resumes from where it left off (HTTP Range header)
- If SHA-256 verification fails, the download is discarded and retried
- Model URL comes from manifest.json — can be updated server-side without an app update
- After this flow completes, the app never requires internet again

---

## Flow 2: Return Visit (Model Already Downloaded)

```
┌──────────────────────────────────────────────────────────────────────┐
│                         RETURN VISIT                                 │
│                                                                      │
│  Open App                                                            │
│      │                                                               │
│      ▼                                                               │
│  _EntryRouter                                                        │
│  disclaimer_accepted == true                                         │
│  model.gguf exists                                                   │
│      │                                                               │
│      ▼                                                               │
│  HomeScreen (immediate)                                              │
│      │                                                               │
│  LlmService.loadModel() runs in background                           │
│  "AI model is loading…" banner shown until ready                    │
│      │                                                               │
│      ▼                                                               │
│  Model ready → banner disappears → chat enabled                      │
└──────────────────────────────────────────────────────────────────────┘
```

**Key behavior:** The app is immediately visible — no blocking load screen. Chat input is disabled until the model finishes loading (typically < 5s on a warm device).

---

## Flow 3: Offline Chat (Primary Flow)

The everyday interaction: ask the AI a survival question.

```
┌──────────────────────────────────────────────────────────────────────┐
│                         OFFLINE CHAT                                 │
│                                                                      │
│  HomeScreen → Chat tab                                               │
│      │                                                               │
│      ▼                                                               │
│  ChatScreen                                                          │
│  [Message history]                                                   │
│  [Input field] [Send]                                                │
│      │                                                               │
│  User types: "How do I treat a deep wound?"                         │
│      │                                                               │
│      ▼                                                               │
│  Intent Classification (LLM, ~200ms)                                │
│  → Result: CHAT                                                      │
│      │                                                               │
│      ▼                                                               │
│  RAG Retrieval (SQLite FTS5, <100ms)                                │
│  Retrieved: top-4 chunks from medical/ docs                         │
│      │                                                               │
│      ▼                                                               │
│  Prompt built (PromptBuilder.buildChatPrompt)                        │
│  → System prompt + retrieved context + history + user message       │
│      │                                                               │
│      ▼                                                               │
│  LLM Inference (Gemma 3 1B, background isolate)                     │
│  → Tokens stream in real-time to the chat bubble                    │
│  → BlinkingCursor shown during generation                           │
│      │                                                               │
│  Response displayed                                                  │
│  User can type follow-up question → repeat from top                 │
└──────────────────────────────────────────────────────────────────────┘
```

**Screen:** `ChatScreen`

**Key behavior:**
- If model is still loading, input is disabled with "Loading AI…" hint
- Chat history kept in memory (last 6 turns in context window)
- Intent classification runs on every message and may redirect to ASSESS or GUIDE flows

---

## Flow 4: Situation Assessment (Agentic Flow)

The most powerful flow — for when the user is in active danger and needs a plan.

```
┌──────────────────────────────────────────────────────────────────────┐
│                     SITUATION ASSESSMENT                             │
│                                                                      │
│  HomeScreen → [Assess Situation] FAB (red, always visible)          │
│      │                                                               │
│      ▼                                                               │
│  SituationScreen                                                     │
│  Progress: ████░░░░░░ (1/5)                                          │
│  "Where are you right now?"                                          │
│  hint: jungle, desert, city, mountain…                               │
│  [Text field]  [Next]                                                │
│      │                                                               │
│  Questions (hardcoded Dart strings — NOT generated by LLM):         │
│  Q1: Where are you?                                                  │
│  Q2: Are you or anyone injured?                                      │
│  Q3: What resources do you have?                                     │
│  Q4: How many others are with you?                                   │
│  Q5: What is your immediate goal?                                    │
│      │                                                               │
│  After Q5: [Analyze Situation]                                       │
│      │                                                               │
│      ▼                                                               │
│  "Understanding your situation…" (spinner)                           │
│  ↳ LLM call 1: extract structured JSON from 5 answers               │
│      │                                                               │
│  "Finding relevant survival guides…"                                 │
│  ↳ situation.relevantTopics() scopes RAG retrieval                  │
│  ↳ RagService.retrieveForSituation() fetches top chunks             │
│      │                                                               │
│  "Creating your survival plan…"                                      │
│  ↳ LLM call 2: generate numbered action plan from chunks            │
│  ↳ Steps parsed by regex: N. [PRIORITY: CRITICAL|HIGH|MEDIUM] …    │
│      │                                                               │
│      ▼                                                               │
│  ActionPlanScreen                                                    │
│  ┌─────────────────────────────────────┐                            │
│  │  ● [CRITICAL] Stop the bleeding     │                            │
│  │    Apply direct pressure to wound…  │                            │
│  │    [ ] Mark complete                │                            │
│  │                                     │                            │
│  │  ● [HIGH] Find shelter              │                            │
│  │    Look for natural overhead cover… │                            │
│  │    [ ] Mark complete                │                            │
│  │                                     │                            │
│  │  [Ask AI about this step]          │                            │
│  └─────────────────────────────────────┘                            │
│      │                                                               │
│  User marks steps complete → saved to SQLite                        │
│  App closed → reopened → plan exactly as left                       │
└──────────────────────────────────────────────────────────────────────┘
```

**Screens:** `SituationScreen` → `ActionPlanScreen`

**Key behavior:**
- Questions are hardcoded Dart strings — NOT generated by LLM — for reliability and speed
- Two LLM calls: one for JSON extraction, one for plan generation
- Action plan steps are stored in SQLite — survive app kill/reopen
- "Ask AI about this step" opens `ChatScreen` without topic restriction
- Only one active plan at a time (new assessment marks previous plan inactive)

---

## Flow 5: Topic Browser

Browse survival docs by category without asking a question.

```
┌──────────────────────────────────────────────────────────────────────┐
│                        TOPIC BROWSER                                 │
│                                                                      │
│  HomeScreen → [Topics tab]                                           │
│      │                                                               │
│      ▼                                                               │
│  TopicBrowserScreen                                                  │
│  ┌──────────────────────────────┐                                    │
│  │  [WAR]        [MEDICAL]     │                                    │
│  │  [JUNGLE]     [DESERT]      │                                    │
│  │  [URBAN]      [GENERAL]     │                                    │
│  └──────────────────────────────┘                                    │
│      │                                                               │
│  Tap [MEDICAL]                                                       │
│      │                                                               │
│      ▼                                                               │
│  DocListScreen (Medical)                                             │
│  > Tourniquet Application                                            │
│  > Wound Packing                                                     │
│  > Treating Shock                                                    │
│  > Fracture Splinting                                                │
│  > Dehydration                                                       │
│      │                                                               │
│  Tap [Tourniquet Application]                                        │
│      │                                                               │
│      ▼                                                               │
│  DocReaderScreen                                                     │
│  (Full markdown rendered offline)                                    │
│  # Tourniquet Application                                            │
│  A tourniquet stops life-threatening limb bleeding…                 │
│      │                                                               │
│  [Ask AI] FAB → opens ChatScreen scoped to 'medical' topic          │
└──────────────────────────────────────────────────────────────────────┘
```

**Screens:** `TopicBrowserScreen` → `DocListScreen` → `DocReaderScreen` → `ChatScreen(topicFilter: 'medical')`

**Key behavior:**
- All docs stored locally as Markdown files, rendered offline via `flutter_markdown`
- Doc titles derived from doc IDs (e.g., `medical/tourniquet` → "Tourniquet")
- "Ask AI" opens a chat scoped to that topic — RAG retrieval filtered to that category only

---

## Flow 6: Doc Sync (WiFi, Background)

Silent update of survival docs when the user has internet access.

```
┌──────────────────────────────────────────────────────────────────────┐
│                          DOC SYNC                                    │
│                                                                      │
│  App opens or returns to HomeScreen                                  │
│      │                                                               │
│  SyncStatusBanner.initState() triggers checkForUpdates()            │
│      │                          │                                    │
│      ▼ (WiFi available)         ▼ (no WiFi)                         │
│  Fetch manifest.json            Banner stays hidden                  │
│  Compare version to stored                                           │
│      │                          │                                    │
│      ▼ (newer)                  ▼ (same)                            │
│  Show banner:                   No banner                            │
│  "New survival docs available — Sync"                                │
│      │                                                               │
│  [Sync] tapped                                                       │
│      │                                                               │
│      ▼                                                               │
│  For each doc in manifest:                                           │
│    Compare SHA-256 with local DB checksum                            │
│    If different:                                                     │
│      → Download .md file                                             │
│      → Verify SHA-256                                                │
│      → Write to /files/docs/{topic}/                                │
│      → Delete old chunks from SQLite                                 │
│      → Re-chunk and re-index                                         │
│      │                                                               │
│      ▼                                                               │
│  Banner: "Updated X docs" (auto-hides after 3 seconds)              │
└──────────────────────────────────────────────────────────────────────┘
```

**Widgets:** `SyncStatusBanner` (in `HomeScreen` body column)

**Key behavior:**
- Never downloads docs that haven't changed (SHA-256 comparison)
- App remains fully functional while sync is in progress
- Sync failure is silent — app continues working with existing docs
- Manual sync trigger available in Settings

---

## Flow 7: Step-by-Step Guidance (GUIDE intent)

When a user asks how to do a specific task (triggered by intent classification).

```
┌──────────────────────────────────────────────────────────────────────┐
│                    STEP-BY-STEP GUIDANCE                             │
│                                                                      │
│  ChatScreen                                                          │
│      │                                                               │
│  User types: "Walk me through applying a tourniquet"                │
│      │                                                               │
│  Intent Classification → GUIDE                                       │
│      │                                                               │
│      ▼                                                               │
│  RAG retrieves tourniquet application chunks                        │
│  LLM generates numbered steps                                        │
│  Steps parsed from numbered list                                     │
│      │                                                               │
│      ▼                                                               │
│  StepGuideScreen                                                     │
│  Step 1 of 5                                                         │
│  ─────────────                                                       │
│  Identify the source of bleeding.                                    │
│  It should be on a limb (arm or leg).                                │
│                                                                      │
│  [Tell me more]  [Next →]                                           │
│      │                                                               │
│  [Tell me more] → opens ChatScreen scoped to that topic             │
│  [Next →]       → advances to Step 2                                │
│  [← Back]       → goes to previous step                             │
│  [Done]         → returns to ChatScreen (last step only)            │
└──────────────────────────────────────────────────────────────────────┘
```

**Screens:** `ChatScreen` → `StepGuideScreen` → `ChatScreen(topicFilter: topic)`

**Key behavior:**
- GUIDE intent is detected automatically by intent classification
- Steps are parsed from the LLM's numbered list response
- Each step is shown individually — no scrolling through a wall of text
- "Tell me more" opens a scoped chat without losing the guide

---

## Flow 8: Settings

```
HomeScreen → AppBar [Settings icon]
    │
    ▼
SettingsScreen
  - Storage used: model / docs / DB breakdown
  - Last sync timestamp
  - Manifest version
  - [Sync Now] button
  - [Clear action plan] option
  - App version + model info
```

**Screen:** `SettingsScreen`

---

## Error States

| Situation | User sees |
|---|---|
| No WiFi on first launch | "Connect to WiFi to download the AI model" with Retry button |
| Model download interrupted | Progress saved; Retry resumes from checkpoint |
| Model OOM (too little RAM) | "Failed to load AI model" error in SetupScreen; Retry option |
| Doc sync failure | Silent; banner shows last sync time; existing docs still work |
| LLM returns empty response | "Error: …" shown in chat bubble |
| Corrupted model file | SHA-256 mismatch detected; download discarded; user retries |
| No docs in topic | "No docs available yet. Sync over WiFi to download survival guides." |
| Intent classification fails | Falls through to CHAT flow — always a safe default |
