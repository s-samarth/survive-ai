# Security

What this app's threat model actually is, what has been checked, and what is
still open.

---

## The threat model

Ordinary app-security advice assumes a phone that belongs to one person in a
stable setting. This app is used somewhere else: during a flood, a blackout, a
lathi charge. That changes which risks matter.

**The phone may not stay with its owner.** It gets borrowed, seized, or handed
to a stranger. Chat history is a record of what someone was afraid of and when
— a snakebite at 2am, a question about hiding during a riot. That is more
sensitive than the content itself suggests.

**The network is hostile precisely when it exists.** The app is offline almost
always, but it downloads a ~500 MB model and a corpus of guides over whatever
connection is available. Those files become executable weights and the text
someone acts on in an emergency.

**Nobody will check a signature.** The app spreads by sideload, USB stick and
person-to-person. If a tampered build is installable, it will be installed.

**No accounts, no telemetry, no cloud.** There is no server to breach, no
analytics, no crash reporting, no PII, and no location permission. That removes
most of the usual attack surface and concentrates the rest on the download path
and the APK itself.

---

## What was checked

### Credentials

Scanned the working tree **and the full git history** across all branches for
HF, OpenAI, GitHub, AWS, Google and Slack token formats and private key blocks.
Clean. No `.env`, keystore, or `key.properties` has ever been committed;
`android/key.properties.template` holds placeholders only.

> An HF token was pasted into a development chat during this work. It was never
> used or written to any file, and it does not appear anywhere in this
> repository. It should still be treated as burned and
> [revoked](https://huggingface.co/settings/tokens), because it existed in a
> transcript.

`.gitignore` now covers `.env`, `.env.*`, `*.jks`, `*.keystore`, and
`key.properties` under every path Gradle might read it from. That last one
mattered: the ignore rule named `android/key.properties` while Gradle reads
`android/app/key.properties`, so a real signing config would **not** have been
ignored.

### Remote data that becomes local state

`manifest.json` is fetched from a remote host and the app trusts it enough to
write its contents to disk and hand them to an inference engine. Three fixes at
that boundary:

| was | now |
|---|---|
| `p.join(dir, manifestFilename)` — `path.join` does not interpret `..`, so a manifest naming `../../databases/survive_ai.db` could overwrite the corpus | filenames and subfolders must be a single plain segment; anything else raises before a byte is written |
| `p.join(docsDir, entry.topic)` — same traversal through the topic directory | the topic must match a known `DocTopic`; unknown topics are dropped |
| any URL scheme accepted | `https` required for the manifest, the model, the encoder and every guide |

The HTTPS check matters more than it looks: `minSdk` is 24 and Android only
blocks cleartext by default from API 28, so on the oldest supported devices an
`http://` URL in the manifest would have been fetched in the clear. The
SHA-256 verification does not save you there — the manifest carrying the hash
arrives over the same channel.

`test/services/download_service_test.dart` covers all of it, and the matcher
was verified to actually catch async throws rather than passing vacuously.

### Downloads

Every download is size-checked and then streamed through SHA-256 before being
moved into place. A partial download resumes only when a sidecar proves it came
from the same URL and the same expected content — blindly appending to whatever
`.part` was on disk once produced a file of exactly the right size and entirely
the wrong contents.

### SQL

All user input is parameter-bound. String interpolation in `rawQuery` is
limited to fixed clause fragments and generated `?` placeholders. No injection
path.

### Android manifest

| change | why |
|---|---|
| dropped `WRITE_EXTERNAL_STORAGE` | never used — everything lives in the app's private directory. It asked for a broad, user-visible permission on a phone someone may be handing to a stranger |
| `usesCleartextTraffic="false"` | belt to the HTTPS checks' braces, and it covers API 24–27 where the platform default does not |
| `allowBackup="false"` + `dataExtractionRules` | chat history is excluded from cloud backup and device-to-device transfer. The platform default is to include it |

### Logging

No user query, model answer, or conversation content reaches `debugPrint`.
Diagnostics carry state and token counts only.

### Release signing

The Gradle config falls back to **debug signing** when no keystore is present.
A debug key is the publicly shared Android one, so anything signed with it can
be replaced by an "update" from anyone — for a sideloaded safety app, that is
the whole threat.

`release.yml` refuses to publish without a real keystore, and separately
inspects the finished APK and fails if it turns out debug-signed. Checking the
output beats trusting that a secret was wired up correctly.

---

## What is still open

- **No LICENSE file.** Third-party obligations are recorded in
  [NOTICE.md](../NOTICE.md), but the project's own terms are unstated. Choosing
  one is the owner's decision.
- **No certificate pinning** on the manifest host. HTTPS plus SHA-256 on every
  downloaded file is the current defence; pinning would harden against a
  compromised CA at the cost of breaking every install when the cert rotates.
- **The model is trusted once its hash matches.** The hash comes from the
  manifest, so whoever controls the manifest repository controls what runs.
  Signing the manifest itself is the next step if that becomes a real concern.
- **No on-device encryption** of the chat database. It is inside the app's
  private storage, which is protected by the device lock on a non-rooted phone,
  and excluded from backup. Full encryption would need a key the user supplies,
  which is a poor trade in an emergency.
- **Nothing has run on real hardware yet.** See [TESTING.md](TESTING.md).

### APK contents

The release APK is arm64-v8a only and carries no code for architectures it
cannot run on. `abiFilters` trims Flutter's own engine but not native libraries
inside third-party AARs, so MediaPipe and ONNX Runtime were each shipping every
ABI: 268 MB before excluding them in packaging, 172 MB after, verified by
inspecting the built artifact rather than by reasoning about the config.

Smaller is a security property here as well as a bandwidth one. The app is
installed over patchy connections by people who will not retry a failed 268 MB
download, and unreachable native code is attack surface with no upside.

---

## Reporting a vulnerability

Email the maintainer directly. Do not open a public issue.
