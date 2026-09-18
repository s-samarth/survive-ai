# Keeping Android and iOS in sync

Survive AI ships from one Flutter codebase to two platforms. The Dart half —
`lib/`, the RAG pipeline, the prompt builder, the 130-test suite — is shared by
construction and cannot drift. Everything underneath it can, and does.

This document is about the part that drifts and what stops it.

---

## What actually drifts

Not the app logic. The platform folders:

| Drift | How it shows up |
|---|---|
| Bundle identifier renamed on one side | Two apps in two stores, no upgrade path |
| A version pinned in `Info.plist` | App Store Connect rejects the upload; Android is fine |
| A permission tightened in `AndroidManifest.xml`, never mirrored | iOS fetches the model manifest in the clear |
| A plugin upgrade raises the iOS deployment floor | CocoaPods resolution error, days later, on somebody's Mac |
| An asset added to the Xcode project instead of `pubspec.yaml` | Present in the IPA, missing from the APK |
| `largeHeap` on Android with no iOS memory entitlement | Jetsam kills the app on iPhone, with no crash the user can act on |

None of these is caught by `flutter analyze`. None is caught by a build — a
drifted iOS project compiles perfectly well and behaves differently. They are
caught, if at all, by someone noticing months later.

---

## The mechanism: three layers, cheapest first

### 1. One source of truth, always (`pubspec.yaml` + `lib/`)

Version numbers, assets and every line of app behaviour live here. The platform
projects are told to read from it rather than declare their own:

- `android/app/build.gradle.kts` → `versionCode = flutter.versionCode`
- `ios/Runner/Info.plist` → `CFBundleVersion = $(FLUTTER_BUILD_NUMBER)`
- assets → the `flutter: assets:` block, which Flutter bundles into both

A release tag then sets one number and both platforms follow.

### 2. The parity test, on every push (`test/platform_parity_test.dart`)

The two platform folders are read as data and asserted against each other.
Eighteen checks, grouped by what they protect:

- **app identity** — the iOS bundle id is the Android application id with
  underscores swapped for hyphens (iOS forbids underscores, so the ids cannot be
  literally equal; the mapping is mechanical, which is what makes it checkable).
  All three Xcode build configurations must agree, because Xcode only ever edits
  the one you have open.
- **one version number** — neither platform hardcodes a version.
- **minimum OS** — the Podfile, `IPHONEOS_DEPLOYMENT_TARGET` and the constant in
  the test all say 16.0. It then scans every plugin's `.podspec` in the resolved
  package set and fails if any of them now needs more than 16.0. That is the
  check that earns its keep over time: it turns a future `flutter pub upgrade`
  into a red Linux build instead of a confusing CocoaPods error on a Mac.
- **network posture** — Android refuses cleartext explicitly; iOS parity is the
  *absence* of an `NSAppTransportSecurity` exception, so the test asserts the
  absence. Neither platform may declare a permission or usage description the
  app does not use.
- **backup posture** — see below.
- **device envelope** — arm64 only on both; memory headroom asked for on both;
  the entitlements file is referenced by all three build configurations, because
  an entitlements file nothing points at is a file that does nothing.
- **shared assets** — the retrieval index must be bundled by Flutter, not copied
  into `android/app/src/main/assets` or added to the Xcode project.

It runs on a Linux runner inside the ordinary `flutter test` job. No Mac, no
Xcode, no extra CI cost.

**When it fails, change the platform file, not the test.** A difference that is
genuinely intentional gets written down here with its reason. An exception that
is recorded is parity; an exception that is deleted is drift.

### 3. The macOS build, when it matters (`.github/workflows/ios.yml`)

The parity test proves the iOS project still describes the same app. It cannot
prove the project compiles. That needs Xcode, so it runs on `macos-15`, which
bills at ten times the Linux rate — on every push to a shipping branch and on
tags, but on pull requests only when `ios/`, `pubspec.yaml` or `pubspec.lock`
moved.

It builds unsigned and then checks that all four retrieval-index files are
inside `Runner.app`. The APK job asks the same question, and it matters more on
iOS because the assets arrive through a different mechanism and an empty corpus
is not an error at runtime — it is an app that answers every question with
nothing.

`release.yml` runs the same build at the tag, so a release cannot exist for one
platform and not the other.

---

## Differences that are deliberate

These are the places where doing the same thing on both platforms would be
wrong. Each one is asserted in the parity test in its platform-specific form.

### Backup

Android sets `android:allowBackup="false"` and is done. iOS has no such switch:
everything under Documents goes to iCloud by default, which here means a ~500 MB
model, a 175 MB encoder, a copy of the corpus and a rebuildable SQLite index
landing in a user's 5 GB free tier. Apple's guidelines call that pattern out
specifically and it is a routine review rejection.

The iOS equivalent is per-directory: `PlatformStorage.excludeFromBackup()`
(`lib/services/platform_storage.dart`) over a method channel to
`ios/Runner/AppDelegate.swift`, called by the three services that write to
Documents — `DownloadService`, `SyncService`, `DatabaseService`. On Android
every call is a no-op. The parity test asserts that all three still call it,
because a service that quietly stops calling it puts 500 MB back into iCloud.

Moving the model to `Library/Caches`, which is never backed up, would trade one
problem for a worse one: iOS purges Caches under disk pressure, and an offline
safety app that loses its model on the day it is needed has failed at its only
job. Documents plus the exclusion flag is what Apple actually recommends.

### Memory headroom

`android:largeHeap="true"` raises the Dalvik cap. The iOS analogue is two free
entitlements in `ios/Runner/Runner.entitlements`:
`com.apple.developer.kernel.increased-memory-limit` (raises the jetsam ceiling)
and `...extended-virtual-addressing` (lets the address space grow past the
default, which is what MediaPipe's mmap of the weights needs). Neither takes
effect on a simulator, so a simulator run tells you nothing about whether they
work.

### Sideloading the model

Android's escape hatch from a 500 MB first-launch download is `adb push` into
external storage, which `DownloadService.modelSearchPaths` searches. iOS has no
external storage; the equivalent is `UIFileSharingEnabled` plus
`LSSupportsOpeningDocumentsInPlace`, which exposes the app's Documents folder in
Finder and the Files app. Same outcome, same directory the downloader already
searches, different plumbing.

### Minimum OS

Android is `minSdk 24` (Android 7.0, ~98% of active devices). iOS is 16.0, and
that is not a preference: `flutter_gemma` (MediaPipeTasksGenAI) and
`flutter_onnxruntime` both declare `s.platform = :ios, '16.0'`. Lowering it does
not widen the install base, it breaks pod resolution.

---

## What is still unverified

Honesty about the gap, in the spirit of [TESTING.md](TESTING.md):

- **Nothing here has run on an iPhone.** The iOS project was generated and
  configured on Linux. CI proves it compiles and that the parity invariants
  hold; it does not prove Gemma 2B loads, that the entitlements do their job
  under jetsam, or what the first token costs on an A15.
- **SQLite and FTS5.** `main.dart` routes every platform through
  `sqflite_common_ffi`. On iOS that resolves sqlite3 symbols already linked into
  the process by `sqflite_darwin`. This is the first thing to check on a real
  device — a failure here is not subtle, but it is also not reproducible on a
  Linux runner.
- **Device testing.** `device-test.yml` uses Firebase Test Lab, which is Android
  only. The iOS equivalent would be a separate farm and is not wired up.
