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

## What Makes It Work

### Everything expensive happens before the phone sees it

The 18 guides are identical on every device and never change at runtime. So the
chunking, the indexing and all 201 passage embeddings are computed once, at
build time, and ship with the app. The phone only has to handle the one thing
that cannot be precomputed: the question.

That single decision is what lets a 300M-parameter search model run alongside a
2B answering model on a mid-range phone. Sizing a search model against "read
the whole library at startup" and against "read one question" give completely
different answers.

### It is built for how people actually type in an emergency

Not "How should I treat a snakebite?" but *"saanp ne kaat liya"*, *"chest
pain"*, *"kutte ne kaata, haldi lagau kya"*. The evaluation set is deliberately
weighted toward romanised Hindi, two-word queries, misspellings, and symptoms
described rather than named.

One finding shaped the design: search models trained on Devanagari score
romanised Hindi barely above noise — 28–46% against 60.7% for plain keyword
search. So Hinglish questions bypass the semantic search entirely. Measuring it
is the only reason we know.

### It knows what it does not know

The app answers "what can this do?" from fixed text, declines questions outside
the 18 situations rather than guessing, and checks its own answer against the
guide passages it was given — blocking anything that asserts what the guides
forbid.

### Every claim here is measured

Retrieval quality, answer safety, conversational resilience and response time
all have hand-authored test sets and recorded baselines. Numbers, including the
ones that currently fail their targets, are in
[RESULTS.md](RESULTS.md).

---

## Why Now

Three things have converged to make this possible in 2026:

1. **Geopolitical instability at a 30-year high.** Conflicts in Ukraine, Gaza, Iran, Sudan, and elsewhere have created millions of civilians in dangerous, network-denied situations.

2. **Smartphone penetration in conflict regions is high.** Even in war-torn areas, 60–80% of people carry Android smartphones — the hardware for Survive AI is already in their hands.

3. **On-device AI is finally small enough.** Models like Gemma 2B IT run on a mid-range Android phone with 6 GB RAM, and a 300M search model fits alongside one. A 500 MB download is all that is needed.

---

## Key Differentiators

| Feature | Survive AI | Offline survival apps | ChatGPT / Gemini |
|---|---|---|---|
| Works with zero internet | Always | Static content only | Requires internet |
| AI-powered answers | On-device LLM | Static text only | Cloud LLM |
| Grounded in expert docs | RAG retrieval, not hallucination | N/A | Hallucination risk |
| Sub-3-second first response | Yes (2B model, CPU) | N/A | Network dependent |
| Works on a 6 GB device | Designed for it | Usually | N/A |
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
- **The speed:** Every component is built for the constraints of a 6 GB phone. Retrieval is imperceptible; the first token currently takes about 6 seconds on a laptop against a 3-second target, which is the main open performance problem. Memory stays flat across a long conversation because the attention cache is recycled every turn.
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
