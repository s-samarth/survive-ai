# Survive AI — Product Overview

## The Problem

Every year, millions of people find themselves in life-threatening situations with no internet access and no trained responders nearby. Civilians caught in the crossfire in Iran, Gaza, Sudan, and Ukraine. Aid workers in remote conflict zones. Journalists in hostile environments. Hikers stranded in the wilderness.

In these moments, people need clear, expert guidance — but they can't Google it. They can't call an expert. Their network connection is gone.

Cloud AI is useless when the infrastructure is destroyed. ChatGPT needs a server. Google needs a cell tower. When bombs are falling or you're bleeding in the wilderness, you have your phone — and nothing else.

**There is no reliable, offline-capable AI assistant built for survival. Until now.**

---

## The Solution

**Survive AI** is a fully offline Android app that puts an AI survival expert in your pocket — with no internet required after a one-time setup.

- Download once over WiFi before you leave
- Works completely offline after that — no signal, no account, no subscription
- Ask anything: "How do I treat a deep wound?", "How do I find water in the jungle?", "What do I do if bombs are falling near my home?"
- Every answer is grounded in expert-reviewed survival guides — the AI doesn't hallucinate procedures
- Browse curated survival guides by topic — War, Medical, Jungle, Desert, Urban, General

This isn't a cloud AI with an offline mode. This is an AI that was built from the ground up to never need the cloud.

---

## Why This Is Revolutionary

### Edge AI for the Hardest Use Case

Running AI on a phone is not new. Running AI on a **4GB** phone, alongside a full app, with **sub-3-second response times**, producing **medically grounded answers** that could save someone's life — that is new.

Every AI company is racing to build bigger models, faster GPUs, and more sophisticated cloud infrastructure. Survive AI goes the opposite direction: **the smallest model, the simplest retrieval, the tightest memory budget** — because that's what actually works when someone is bleeding in a bombed-out building with no internet.

### Speed Over Sophistication

In a survival emergency, you don't need the most sophisticated AI. You need the fastest correct answer. This principle drives every technical decision:

- **A 2B model generates its first token in under 3 seconds.** A 7B model takes 10+ seconds and crashes on 4GB devices. When someone is applying a tourniquet, 7 seconds matters.
- **BM25 keyword search retrieves relevant chunks in under 50 milliseconds.** Vector embeddings would take 200ms and require 200MB of additional RAM that doesn't exist.
- **Query expansion bridges vocabulary gaps with zero memory cost.** A user says "I'm bleeding" — the system also searches for "hemorrhage," "tourniquet," "wound," and "pressure." This is done with a pure Dart dictionary, not a neural model.
- **Answers are grounded in expert-reviewed survival guides.** The AI doesn't invent procedures. It retrieves relevant documentation and generates answers from that evidence.

### The Constraint That Creates the Innovation

Most AI products start with "what's the best model?" and work backwards to find users. Survive AI starts with the user — a person in a life-threatening situation with a 4GB Android phone and no internet — and works backwards to find the architecture that serves them.

This constraint forced innovations that have no equivalent in cloud AI:

1. **Instruction-last prompt engineering** — placing the AI's behavioral instruction right before the question, not at the top of the prompt, because small models "forget" instructions that appear early in the context
2. **Query expansion as a replacement for neural embeddings** — 130+ hand-crafted survival-domain synonym mappings that bridge the gap between how panicked people talk and how medical guides are written, using zero memory
3. **KV cache recycling** — destroying the attention cache between conversation turns to keep RAM usage flat, because on a 4GB device there's no room for memory growth
4. **Reciprocal Rank Fusion** — merging multiple retrieval signals (exact keywords + expanded synonyms) into a single ranking, so the system finds relevant content even when the user's words don't match the document's terminology

---

## Why Now

Three things have converged to make this possible in 2026:

1. **Geopolitical instability at a 30-year high.** Conflicts in Ukraine, Gaza, Iran, Sudan, and elsewhere have created millions of civilians in dangerous, network-denied situations.

2. **Smartphone penetration in conflict regions is high.** Even in war-torn areas, 60–80% of people carry Android smartphones — the hardware for Survive AI is already in their hands.

3. **On-device AI is finally small enough.** Models like Gemma 2B IT run on a mid-range Android phone with 4GB RAM. A 500MB download is all that's needed. This wasn't possible even 12 months ago.

---

## Key Differentiators

| Feature | Survive AI | Offline survival apps | ChatGPT / Gemini |
|---|---|---|---|
| Works with zero internet | Always | Static content only | Requires internet |
| AI-powered answers | On-device LLM | Static text only | Cloud LLM |
| Grounded in expert docs | RAG retrieval, not hallucination | N/A | Hallucination risk |
| Sub-3-second first response | Yes (2B model, CPU) | N/A | Network dependent |
| Works on 4GB device | Designed for it | Usually | N/A |
| Community survival docs | Open-source, reviewed | Not available | N/A |
| Cost to user | Free | Varies | Subscription |
| No account required | Yes | Yes | No |
| Distributable via USB | Yes (direct APK) | No | No |

---

## How It Works

### First Launch (WiFi required, one time only)
1. User opens the app and accepts the safety disclaimer
2. App detects WiFi and fetches `manifest.json` from GitHub
3. Downloads the on-device AI model (~500MB, resumable)
4. Downloads initial survival docs and indexes them into local SQLite
5. Ready — disconnect from the internet. The app works forever offline.

### Every Day After (fully offline)
- **Ask anything** — AI answers using expert survival knowledge retrieved from local docs
- **Vocabulary-bridged search** — "I'm bleeding" finds docs about "hemorrhage control" and "tourniquet application" through automatic query expansion
- **Read docs** — browse survival guides by topic
- **Fast answers** — first token in under 3 seconds, full response in 15-30 seconds

### When WiFi is available again
- App silently checks for new or updated survival docs
- Downloads only what has changed (SHA-256 checksum comparison)
- User never loses offline functionality during or after sync

---

## Target Users

**Primary:** Civilians in active conflict zones. People who know or suspect they may soon be in danger and want to prepare. Currently focused on Android given high prevalence in target regions.

**Secondary:**
- Journalists and aid workers in hostile environments
- Hikers, campers, and wilderness adventurers
- Emergency preparedness enthusiasts
- NGO field staff

---

## Survival Doc Categories

| Category | Example Topics |
|---|---|
| War | Ambush response, IED awareness, checkpoint crossing, cover and concealment, blast shelter |
| Medical | Tourniquet application, wound packing, shock treatment, fracture splinting, dehydration |
| Jungle | Water finding, water purification, shelter building, navigation without tools |
| Desert | Heat management, water conservation, shade finding, signaling |
| Urban | Building search, escape routes, improvised shelter, earthquake response |
| General | Fire starting, signaling for rescue, survival psychology, navigation |

Docs are open-source, community-contributed, and reviewed by subject matter experts before publication. All medical content requires SME review.

---

## Technology (Non-Technical Summary)

- **The AI brain:** Gemma 2B IT — a small language model from Google, running entirely on your phone via MediaPipe. No internet needed.
- **The knowledge base:** Expert survival guides stored locally and retrieved automatically based on what you ask. The AI also expands your words with related survival terms to find the right information, even when you're panicking and can't use precise medical language.
- **The speed:** Every component is optimized for the constraints of a 4GB phone. The system retrieves relevant knowledge in under 50 milliseconds, starts generating an answer in under 3 seconds, and manages memory so the app never crashes — even after dozens of conversations.
- **The app:** Built with Flutter for Android. Distributed as a direct APK — no app store required.
- **Cost to build and run:** $0 — entirely open-source

---

## Business Model

Survive AI is a humanitarian open-source project. There is no monetization goal. The mission is to put life-saving AI in the hands of people who need it most, for free, with no barriers to access.

Distribution via APK sideload is intentional — it allows the app to spread via USB sticks, local mesh networks, and peer-to-peer sharing in environments where app stores are inaccessible.

---

## Future Vision

- **Multi-language support** — Arabic, Farsi, Ukrainian (the languages of people who need this most)
- **Dense semantic search** — vector embeddings for even better retrieval when device RAM allows (the infrastructure is already built)
- **Offline maps** — downloadable regional maps from OpenStreetMap
- **Voice interface** — speak questions, hear answers (critical when hands are injured or occupied)
- **Mesh networking** — share updated docs device-to-device via Bluetooth, no internet needed
- **iOS** — Flutter makes cross-platform straightforward once Android is stable
- **NGO partnerships** — pre-loaded on devices distributed by MSF, IRC, UN OCHA

---

## Metrics of Impact

Success is not measured in revenue. It is measured in:
- Number of app downloads
- Number of survival doc queries answered offline
- Geographic distribution of users (particularly in active conflict regions)
- Number of community doc contributions merged
- Feedback from NGOs and field workers
