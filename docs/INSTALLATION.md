# Installation, Running & Deployment — Survive AI

This document covers everything needed to get Survive AI onto a device — whether you're a developer running it locally, an NGO deploying it to field workers, or an end user sideloading it onto an Android phone.

---

## Table of Contents

1. [User Installation (Sideload APK)](#1-user-installation-sideload-apk)
2. [Developer Setup (Run from Source)](#2-developer-setup-run-from-source)
3. [Building a Release APK](#3-building-a-release-apk)
4. [NGO / Field Deployment](#4-ngo--field-deployment)
5. [Verifying APK Authenticity](#5-verifying-apk-authenticity)
6. [Troubleshooting](#6-troubleshooting)

---

## 1. User Installation (Sideload APK)

Survive AI is distributed as a direct APK — no Google Play Store account or internet connection required after install.

### Step 1: Enable Unknown Sources

On the target Android device:

1. Open **Settings**
2. Navigate to **Security** (or **Privacy** on newer Android versions)
3. Enable **"Install unknown apps"** or **"Allow from this source"**
   - On Android 8+: go to **Settings → Apps → Special App Access → Install Unknown Apps** and enable it for your file manager or browser

### Step 2: Transfer the APK

Choose the method that works in your environment:

**Option A — USB stick / direct transfer:**
```
Copy app-release.apk to the device via USB cable or USB OTG adapter
```

**Option B — Direct download (if internet is available):**
```
Open the GitHub Releases page on the device browser
Download app-release.apk
```

**Option C — Bluetooth / WiFi Direct:**
```
Share the APK file via Bluetooth or WiFi Direct from another device that already has it
```

**Option D — Local network:**
```
Host the APK on a local HTTP server (e.g. python3 -m http.server 8080)
Open http://<your-ip>:8080/app-release.apk on the device browser
```

### Step 3: Install

1. Open your file manager
2. Navigate to where the APK is saved (typically `Downloads/`)
3. Tap `app-release.apk`
4. Tap **Install**
5. If prompted about Play Protect, tap **Install Anyway**

### Step 4: First Launch Setup

The app requires a **one-time WiFi connection** to download the AI model (~500MB) and initial survival docs.

1. Open **Survive AI**
2. Read and accept the disclaimer
3. Connect to WiFi when prompted
4. Wait for the download to complete (progress bar shows percentage)
5. The app will index the docs and load the AI model
6. You're ready — disconnect from the internet. The app works fully offline from here.

**The download is resumable.** If it's interrupted, tap Retry and it will continue from where it left off.

---

## 2. Developer Setup (Run from Source)

### Prerequisites

**Flutter SDK:**
```bash
# macOS (via Homebrew)
brew install --cask flutter

# Verify
flutter doctor
```

Ensure the following are checked in `flutter doctor` output:
- Flutter SDK installed
- Android toolchain (Android SDK + NDK)
- At least one connected device or emulator

**Android Setup:**
- Android Studio (for SDK manager and emulator)
- Android SDK with Build Tools 34+
- NDK version 27+ (required by llama_cpp_dart for native compilation)
- A physical device or emulator running Android 7.0+ (API 24+)

### Clone and Install

```bash
git clone https://github.com/survive-ai/survive-ai.git
cd survive-ai
flutter pub get
```

### Run in Debug Mode

```bash
# List connected devices
flutter devices

# Run on a specific device (hot reload enabled)
flutter run -d <device-id>

# Run on the first available Android device
flutter run -d android
```

**Note on the LLM model in development:** The model download requires a working manifest URL. To test LLM inference locally without waiting for the manifest:

1. Download the GGUF model manually from HuggingFace
2. Copy it to the device: `adb push gemma-3-1b-it-Q4_K_M.gguf /sdcard/Download/`
3. Temporarily modify `DownloadService` to use a local path, or place the file directly in the app's files directory via `adb`

### Run in Release Mode

```bash
flutter run --release -d <device-id>
```

Release mode disables debug overlays and hot reload, but gives you production-level performance — important for benchmarking LLM inference speed.

### Running Tests

```bash
# Run all tests
flutter test

# Run a specific test file
flutter test test/services/chunker_service_test.dart
```

### Static Analysis

```bash
flutter analyze
```

Zero warnings required. If any warnings appear, fix them before committing.

---

## 3. Building a Release APK

### Debug APK (for development/testing)

```bash
flutter build apk --debug
# Output: build/app/outputs/flutter-apk/app-debug.apk
```

### Release APK (unsigned, for local distribution)

```bash
flutter build apk --release
# Output: build/app/outputs/flutter-apk/app-release.apk
```

This uses the debug signing key by default — sufficient for sideloading and testing.

### Release APK (signed with production key)

For official releases, signing is configured via `android/key.properties` (not in git):

```bash
# 1. Create your keystore (one-time setup)
keytool -genkey -v \
  -keystore ~/survive-ai.jks \
  -keyalg RSA -keysize 2048 \
  -validity 10000 \
  -alias survive-ai

# 2. Create android/key.properties (never commit this file)
cat > android/key.properties << EOF
storePassword=<your-keystore-password>
keyPassword=<your-key-password>
keyAlias=survive-ai
storeFile=/Users/<you>/survive-ai.jks
EOF

# 3. Build the signed release APK
flutter build apk --release
```

### Computing the APK Checksum

Always publish the SHA-256 alongside the APK so users can verify authenticity:

```bash
shasum -a 256 build/app/outputs/flutter-apk/app-release.apk
```

Paste the output into the GitHub Release notes.

---

## 4. NGO / Field Deployment

For organizations deploying Survive AI to multiple devices in the field:

### Pre-loading a Custom Doc Set

You can configure a custom manifest URL pointing to your own GitHub fork of `survive-ai-docs`, pre-loaded with your organization's specific survival content:

1. Fork [survive-ai-docs](https://github.com/survive-ai/survive-ai-docs)
2. Add your docs to `docs/{topic}/` and update `manifest.json`
3. Update the `_manifestUrl` constant in `lib/services/sync_service.dart` to point to your fork's raw manifest URL
4. Build a release APK from that source — this becomes your organization's pre-configured build

### Mass Deployment via USB

For deploying to many devices without internet:

```bash
# Install on a connected device via ADB
adb install app-release.apk

# Scripted install to all connected devices
for device in $(adb devices | grep -v 'List' | awk '{print $1}'); do
  adb -s $device install app-release.apk
done
```

After install, the model and docs still need to be downloaded on first launch. To pre-load them without requiring each device to download:

```bash
# 1. Set up one device fully (download model + docs via the app)
# 2. Pull the app's files directory
adb pull /data/user/0/com.surviveai.survive_ai/files/ ./survive_ai_files/

# 3. Push to other devices (requires root or ADB backup permissions)
adb push ./survive_ai_files/ /data/user/0/com.surviveai.survive_ai/files/
```

**Note:** The `adb pull` from the app's private data directory requires either a debuggable APK or ADB backup permissions. For production deployment, build a debug variant specifically for mass pre-loading, then replace with the release APK.

### USB Stick Distribution

Include the following on the USB stick:
```
usb-stick/
├── app-release.apk            (the Survive AI APK)
├── SHA256.txt                 (checksum of the APK)
├── INSTALL.txt                (plain-text installation steps)
└── model/                     (optional: pre-downloaded model file)
    └── model.gguf
```

If the model file is included on the USB stick, users can avoid the WiFi download by copying it to the device's `Downloads/` folder before first launch. The app will detect it and skip the download step.

---

## 5. Verifying APK Authenticity

Before installing a downloaded APK, verify it hasn't been tampered with:

**macOS:**
```bash
shasum -a 256 app-release.apk
```

**Linux:**
```bash
sha256sum app-release.apk
```

**Windows (PowerShell):**
```powershell
Get-FileHash app-release.apk -Algorithm SHA256
```

Compare the output to the SHA-256 published in the GitHub Release notes. If they don't match, do not install the APK.

You can also verify the APK signing certificate:
```bash
# Extract and check the signing certificate
apksigner verify --print-certs app-release.apk
```

The maintainer's signing key fingerprint is published in `SECURITY.md`.

---

## 6. Troubleshooting

### The model won't load

- Check that `model.gguf` is in `/data/user/0/com.surviveai.survive_ai/files/models/`
- Verify the device has at least 1.5GB free RAM (close background apps)
- Check `adb logcat` for native crash output from llama.cpp:
  ```bash
  adb logcat | grep -E "llama|survive_ai"
  ```

### The model download keeps failing

- Check internet connectivity
- The download is resumable — tap Retry and it will continue from where it stopped
- If SHA-256 verification fails repeatedly, the source file may have changed — check for a new manifest version

### No docs appear in the topic browser

- Docs are only present after a sync. Connect to WiFi and trigger a manual sync in Settings.
- Check that chunks were inserted into `chunks_fts` (not just `chunks`) by examining logs
- FTS5 MATCH syntax is strict — check the query format in `DatabaseService.searchFts()`

### FTS5 search returns no results

- Verify the porter stemmer is active: "running" matches "run", "wounds" matches "wound"
- Avoid special characters in search queries — FTS5 MATCH treats them as operators
- Check that the `chunks_fts` virtual table was created correctly (not just `chunks`)

### flutter run fails with NDK errors

- Ensure NDK is installed: open Android Studio → SDK Manager → SDK Tools → NDK
- Verify the version: `llama_cpp_dart` requires NDK 27+
- Set the NDK path explicitly in `android/local.properties`:
  ```
  ndk.dir=/Users/<you>/Library/Android/sdk/ndk/27.x.x.xxxxxxx
  ```

### flutter analyze reports issues

- Run `flutter pub get` first to ensure all dependencies are resolved
- Check if a new dependency introduced a conflicting lint rule

### Riverpod provider causes infinite rebuild

- Never call `ref.watch()` inside a loop or conditional — use `ref.read()` for one-time reads
- Use `ref.read()` in button callbacks, use `ref.watch()` in the `build()` method only

### SHA-256 mismatch on doc download

- Verify the checksum in `manifest.json` was computed from the exact UTF-8 bytes of the file
- Watch for trailing newline differences: `shasum -a 256` (macOS) and `sha256sum` (Linux) produce identical output for the same bytes
- Re-compute: `shasum -a 256 docs/medical/tourniquet.md`

---

## Platform Requirements

| Requirement | Minimum | Recommended |
|---|---|---|
| Android version | 7.0 (API 24) | 10.0+ (API 29+) |
| RAM | 3GB | 4GB+ |
| Storage | 1GB free | 2GB+ free |
| CPU | ARMv7 (armeabi-v7a) | ARM64 (arm64-v8a) |
| Internet | WiFi for first launch | Not required after setup |

The app is compiled for both `arm64-v8a` (64-bit) and `armeabi-v7a` (32-bit) to cover the broadest range of Android devices in conflict regions.
