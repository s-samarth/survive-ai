# Survive AI — Product Overview

## The Problem

Every year, millions of people find themselves in life-threatening situations with no internet access and no trained responders nearby. Civilians caught in the crossfire in Iran, Gaza, Sudan, and Ukraine. Aid workers in remote conflict zones. Journalists in hostile environments. Hikers stranded in the wilderness.

In these moments, people need clear, expert guidance — but they can't Google it. They can't call an expert. Their network connection is gone.

**There is no reliable, offline-capable AI assistant built for survival.**

---

## The Solution

**Survive AI** is a fully offline Android app that puts an AI survival expert in your pocket — with no internet required after a one-time setup.

- Download once over WiFi before you leave
- Works completely offline after that — no signal, no account, no subscription
- Ask it anything: "How do I treat a deep wound?", "How do I find water in the jungle?", "What do I do if I'm under fire?"
- It walks you through step-by-step, remembers your situation, builds you a survival plan
- Browse curated survival guides by topic — War, Medical, Jungle, Desert, Urban, General
- Action plans are saved locally and survive app restarts — your plan is there when you reopen the app

---

## Why Now

Three things have converged to make this possible in 2026:

1. **Geopolitical instability at a 30-year high.** Conflicts in Ukraine, Gaza, Iran, Sudan, and elsewhere have created millions of civilians in dangerous, network-denied situations.

2. **Smartphone penetration in conflict regions is high.** Even in war-torn areas, 60–80% of people carry Android smartphones — the hardware for Survive AI is already in their hands.

3. **On-device AI is finally small enough.** Models like Gemma 3 1B run on a mid-range Android phone with 3GB RAM. A 500MB download is all that's needed. This wasn't possible even 12 months ago.

---

## Key Differentiators

| Feature | Survive AI | Offline survival apps | ChatGPT / Gemini |
|---|---|---|---|
| Works with zero internet | Always | Static content only | Requires internet |
| AI-powered answers | On-device LLM | Static text only | Cloud LLM |
| Situation assessment | Guided interview + AI plan | Not available | Not available |
| Step-by-step action plan | Generated + persistent | Not available | Session only |
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
- **Get guided** — describe your situation, receive a prioritized action plan
- **Read docs** — browse survival guides by topic
- **Check off steps** — action plans persist across app restarts

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
| War | Ambush response, IED awareness, checkpoint crossing, cover and concealment |
| Medical | Tourniquet application, wound packing, shock treatment, fracture splinting, dehydration |
| Jungle | Water finding, water purification, shelter building, navigation without tools |
| Desert | Heat management, water conservation, shade finding, signaling |
| Urban | Building search, escape routes, improvised shelter |
| General | Fire starting, signaling for rescue, survival psychology |

Docs are open-source, community-contributed, and reviewed by subject matter experts before publication. All medical content requires SME review.

---

## Technology (Non-Technical Summary)

- **The AI brain:** Gemma 3 1B — a state-of-the-art small language model from Google, running entirely on-device via llama.cpp
- **The knowledge base:** Expert survival guides stored locally and retrieved automatically based on what you ask (BM25 full-text search)
- **The agentic layer:** Intent classification routes each message to the right flow — chat, situation assessment, or step-by-step guidance
- **The app:** Built with Flutter for Android. Distributed as a direct APK — no app store required.
- **Cost to build and run:** $0 — entirely open-source

---

## Business Model

Survive AI is a humanitarian open-source project. There is no monetization goal. The mission is to put life-saving AI in the hands of people who need it most, for free, with no barriers to access.

Distribution via APK sideload is intentional — it allows the app to spread via USB sticks, local mesh networks, and peer-to-peer sharing in environments where app stores are inaccessible.

---

## Future Vision

- **Multi-language support** — Arabic, Farsi, Ukrainian (the languages of people who need this most)
- **Semantic search** — vector embeddings for queries like "I can't breathe" finding "respiratory distress" docs
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
- Number of situation assessments completed
- Number of community doc contributions merged
- Geographic distribution of users (particularly in active conflict regions)
