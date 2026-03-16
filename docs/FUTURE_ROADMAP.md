# Future Roadmap — Survive AI

This document outlines what comes after the MVP (Phases 0–4). Items are grouped into three horizons based on effort and dependency on earlier work.

---

## What the MVP Delivers (Phases 0–4, Complete)

The current implementation is a fully working offline Android app:

- Flutter Android app with on-device Gemma 2B IT (`gemma-2b-it-cpu-int4.bin`, ~500MB) via flutter_gemma (MediaPipe LLM Inference)
- First-launch flow: disclaimer, WiFi check, resumable model download, SHA-256 verification, doc sync
- RAG over community survival docs — BM25 keyword search via SQLite FTS5
- Offline chat: user message → BM25 retrieval → prompt built → LLM streams response
- Topic browser: 6 categories (War, Medical, Jungle, Desert, Urban, General) with Markdown doc reader
- WiFi-gated doc sync: download only changed docs, verify checksums, re-index
- Sync status banner: notifies user when new docs are available
- Settings screen: storage info, manual sync
- Direct APK distribution — no app store required

---

## Near-Term (Post-MVP)

### Intent Classification & Agentic Routing
**Why it matters:** Currently, all user messages go through the chat flow. Adding intent classification (CHAT, ASSESS, GUIDE) would allow the app to automatically route messages to the right experience.

**What this enables:**
- Intent classification: each message routed to CHAT, ASSESS, or GUIDE flow
- Situation assessment: 5 guided questions, LLM extraction of structured JSON, RAG-augmented action plan generation
- Persistent action plans stored in SQLite — survive app kill and reopen
- Step-by-step guidance screen for task-specific instruction

**Effort:** Medium — the data model and prompt templates need to be designed and validated.

---

### Multi-Language Support
**Why it matters:** The highest-risk populations are in Arabic, Farsi, and Ukrainian-speaking regions. English-only is a barrier.

**Approach:**
- Translate the app UI strings via Flutter's `l10n` system
- Translate survival docs — start with the 20 most critical docs in Arabic and Farsi
- Consider multilingual embedding model for Phase 2 RAG (e.g., `paraphrase-multilingual-MiniLM-L12-v2`)
- Evaluate multilingual SLMs (Gemma 3 has some multilingual capability; Aya-Expanse models are explicitly multilingual)

**Effort:** Medium — UI localization is straightforward; doc translation requires human review by native speakers.

---

### Semantic Search (RAG Phase 2)
**Why it matters:** BM25 fails when keywords don't match. "I can't breathe" won't find "respiratory distress" docs. Semantic search bridges this gap.

**Approach:**
- Add `all-MiniLM-L6-v2.onnx` (~22MB embedding model) via `onnxruntime_flutter`
- Add `sqlite-vec` SQLite extension for on-device vector search
- Hybrid BM25 + vector retrieval with RRF re-ranking
- Generate embeddings for all chunks at ingestion time; store in `chunks.embedding` (column already in schema)

**Effort:** Medium — packages exist, the schema already has the `embedding BLOB` column, integration is the main work.

---

### Voice Interface
**Why it matters:** In a survival emergency, hands may be occupied, injured, or shaking. Speaking is faster than typing. Hearing an answer is easier than reading while moving.

**Approach:**
- Voice input: Flutter's `speech_to_text` package (on-device, Android native ASR)
- Voice output: `flutter_tts` package (on-device text-to-speech)
- Wake word (future): Consider wake-word detection so users can activate without touching the screen

**Effort:** Low-Medium — both packages are mature and work offline on Android.

---

### Offline Maps Integration
**Why it matters:** Knowing where you are and how to navigate is fundamental to survival. "Head south-west" is useless without a map.

**Approach:**
- OpenStreetMap tiles downloadable by region (`flutter_map` + MBTiles format)
- Pre-built region packs: "Middle East", "Sub-Saharan Africa", "Eastern Europe"
- GPS integration (already available on all Android devices)
- AI guidance can reference map data: "You are ~4km from the nearest road"

**Effort:** Medium-High — map tile storage is large (region packs can be 500MB–2GB).

---

## Medium-Term

### Mesh Networking — Device-to-Device Doc Sync
**Why it matters:** In a conflict zone, one person may have internet access (via satellite or a brief connection window). That person should be able to share updated docs with everyone nearby — without internet.

**Approach:**
- WiFi Direct (Android P2P): devices form a local network without a router
- Bluetooth: for shorter range doc transfer
- Protocol: compare manifest.json versions; transfer only delta (changed docs)
- **Meshtastic integration** (long-range): Meshtastic devices (LoRa radio) can carry small payloads over kilometers; could carry manifest updates or small doc chunks

**Effort:** High — requires significant protocol work, but the impact is enormous for the core use case.

---

### Medical Triage Module
**Why it matters:** Medical emergencies are the most common and time-sensitive survival situation.

**Approach:**
- Partner with Red Cross / IFRC to get their START triage protocol as verified content
- Build a dedicated triage flow: assessment questions, patient category (immediate/delayed/minor/expectant)
- Connect to Médecins Sans Frontières (MSF) to validate content
- Include ICD-coded symptom recognition to ensure clinical accuracy

**Effort:** Medium (technical) + High (partnerships and content validation)

---

### iOS Port
**Why it matters:** While Android is dominant in conflict regions, iOS users exist — particularly among journalists, aid workers, and NGO staff who often carry iPhones.

**Approach:**
- Flutter makes this relatively straightforward — most code is shared
- `flutter_gemma` supports iOS via MediaPipe LLM Inference
- Model download requires iOS file management (different path conventions)
- App Store distribution vs. TestFlight for NGO pilots

**Effort:** Medium — Flutter handles most of it; testing on iOS hardware is the main cost.

---

### NGO Partnership Program
**Why it matters:** The highest-impact distribution channel is through organizations already working in conflict zones — MSF, IRC, UN OCHA, Save the Children, UNHCR.

**Approach:**
- Develop a "pre-configured APK" pipeline: NGOs can request a build with their specific doc set pre-loaded and their branding
- Offer a simple web tool for NGOs to manage their doc set (PR to survive-ai-docs with approval)
- Establish a Medical Advisory Board for validating health-related content
- Approach ICRC (International Committee of the Red Cross) for humanitarian-law content

**Effort:** Primarily relationship and process work; technically straightforward.

---

## Long-Term Vision

### Hardware Integration
Use the device's sensors to provide more precise guidance:

- **GPS + compass:** Real-time navigation guidance ("Walk 2.3km north-north-east to reach the road")
- **Barometric pressure:** Weather prediction ("Pressure dropping — storm likely in 4–6 hours")
- **Camera (future):** Plant identification for foraging, wound assessment
- **Accelerometer:** Detect a fall or sudden stillness (potential incapacitation alert)

---

### Satellite Connectivity Fallback
In truly network-denied environments, even WiFi isn't available. But satellite is.

- Starlink: consumer-priced satellite internet; becoming available in conflict regions
- Iridium/Globalstar: expensive but available everywhere
- When satellite is detected, trigger a model update or critical doc sync

---

### Community Translation Platform
A web interface where volunteers can:
- Browse survival docs in English
- Submit translations in any language
- Flag translations for review by native speakers
- Maintainers approve and merge into the docs repo

---

### Government & Institutional Pre-Loading
Partner with civil defense agencies, emergency management organizations, and disaster preparedness bodies to:
- Pre-install Survive AI on emergency response devices
- Include Survive AI in disaster preparedness kits (USB stick with APK + model)
- Work with telecom providers to offer the model download at zero data cost (zero-rating)

---

## What We Will NOT Build

To keep the project focused and the app trustworthy:

- **No real-time communication features.** Survive AI is not a messaging app. It does not send or receive messages.
- **No location tracking or telemetry.** We will never know where users are or what they ask.
- **No paid features.** The humanitarian mission requires zero cost to the end user.
- **No AI-generated medical prescriptions.** We provide general guidance; we explicitly disclaim specific dosages. This is a firm line.
- **No political content.** The app is politically neutral. Survival knowledge is universal.

---

## Open Questions

1. **What SLM is right for low-end devices?** Gemma 2B IT is the current choice, but as quantization improves and better small models emerge, we should re-evaluate. The manifest.json model URL allows this upgrade without a new app release.

2. **How do we validate medical content?** The biggest risk to user trust is incorrect medical guidance. We need a Medical Advisory Board before the medical docs go beyond basic first aid.

3. **How do we handle adversarial contributions?** A community-contributed doc repo is a potential vector for harmful content. We need strong maintainer guidelines, PR review requirements, and possibly automated content scanning.

4. **When does the RAG context window become insufficient?** As the doc set grows, retrieval quality matters more. Phase 2 (semantic search) should be prioritized before the doc count exceeds ~200 docs.

5. **How do we measure impact in conflict zones?** Standard analytics are off the table (no telemetry). We need to think creatively about measuring reach — perhaps opt-in anonymous download counts, or NGO self-reporting.
