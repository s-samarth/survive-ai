import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:survive_ai/services/platform_storage.dart';

/// Android and iOS ship the same app, and nothing enforces that on its own.
///
/// The Dart half of this project is already shared — one `lib/`, one test
/// suite, one RAG pipeline. What drifts is everything underneath it: a bundle
/// identifier renamed on one side, a version pinned in an Info.plist, a
/// permission tightened in AndroidManifest.xml and never mirrored, a plugin
/// upgrade that quietly raises the iOS floor above what the Podfile declares.
/// None of that is caught by `flutter analyze`, and none of it is caught by a
/// build — a drifted iOS project builds perfectly well and behaves differently.
///
/// So the two platform folders are treated as data and asserted against each
/// other here. This runs inside the ordinary `flutter test` job on a Linux
/// runner: no Mac, no Xcode, no extra CI cost. The macOS build job in CI proves
/// the iOS project compiles; this proves it is still the same app.
///
/// **When one of these fails, change the platform file, not the test.** If a
/// difference is genuinely intentional, record it here with the reason — an
/// exception that is written down is parity, an exception that is deleted is
/// drift.
void main() {
  // ── Shared source of truth ────────────────────────────────────────────────
  // These four values are what "the same app" means. Every assertion below
  // traces back to one of them.
  const applicationId = 'com.surviveai.survive_ai';
  const displayName = 'Survive AI';
  const minimumIosVersion = '16.0';
  const minimumAndroidSdk = 24;

  /// iOS bundle identifiers may not contain underscores, so the two ids cannot
  /// be character-for-character equal. The mapping is fixed and mechanical
  /// rather than a free choice, which is what keeps it checkable.
  String iosBundleIdFor(String androidApplicationId) =>
      androidApplicationId.replaceAll('_', '-');

  late final String manifest;
  late final String gradle;
  late final String infoPlist;
  late final String pbxproj;
  late final String podfile;
  late final String entitlements;
  late final String appDelegate;
  late final String pubspec;
  late final String metadata;

  /// XML and plist comments are stripped before anything is asserted.
  ///
  /// Several of the checks below are *absence* checks — an ATS exception, an
  /// unused permission — and both platform files explain in comments exactly
  /// which key they are deliberately not setting. Matching on the raw text
  /// would make those explanations fail the test they document.
  String stripXmlComments(String xml) =>
      xml.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');

  String read(String path) {
    final file = File(path);
    expect(
      file.existsSync(),
      isTrue,
      reason: '$path is missing. Both platform folders are checked in.',
    );
    return file.readAsStringSync();
  }

  setUpAll(() {
    manifest = stripXmlComments(
      read('android/app/src/main/AndroidManifest.xml'),
    );
    gradle = read('android/app/build.gradle.kts');
    infoPlist = stripXmlComments(read('ios/Runner/Info.plist'));
    pbxproj = read('ios/Runner.xcodeproj/project.pbxproj');
    podfile = read('ios/Podfile');
    entitlements = stripXmlComments(read('ios/Runner/Runner.entitlements'));
    appDelegate = read('ios/Runner/AppDelegate.swift');
    pubspec = read('pubspec.yaml');
    metadata = read('.metadata');
  });

  /// The value of `<key>name</key>` in a plist, for `<string>` values.
  String? plistString(String plist, String key) {
    final match = RegExp(
      '<key>${RegExp.escape(key)}</key>\\s*<string>([^<]*)</string>',
    ).firstMatch(plist);
    return match?.group(1);
  }

  /// True when `<key>name</key>` is followed by `<true/>`.
  bool plistIsTrue(String plist, String key) =>
      RegExp('<key>${RegExp.escape(key)}</key>\\s*<true/>').hasMatch(plist);

  group('both platforms exist', () {
    test('the repository carries an android/ and an ios/ project', () {
      expect(Directory('android').existsSync(), isTrue);
      expect(Directory('ios').existsSync(), isTrue);
    });

    test('.metadata lists both, so `flutter migrate` upgrades both', () {
      // `flutter create --platforms=ios .` rewrites this block and has been
      // observed replacing the android entry instead of appending to it, which
      // silently drops Android out of every future template migration.
      expect(metadata, contains('- platform: android'));
      expect(metadata, contains('- platform: ios'));
    });
  });

  group('app identity', () {
    test('the bundle identifier is the application id, underscores aside', () {
      expect(gradle, contains('applicationId = "$applicationId"'));
      final expected = iosBundleIdFor(applicationId);
      expect(expected, 'com.surviveai.survive-ai');

      final ids = RegExp(
        r'PRODUCT_BUNDLE_IDENTIFIER = "?([^";\n]+)"?;',
      ).allMatches(pbxproj).map((m) => m.group(1)!).toSet();
      expect(ids, isNotEmpty);
      for (final id in ids) {
        // The test target legitimately appends a suffix.
        final base = id.replaceAll('.RunnerTests', '');
        expect(
          base,
          expected,
          reason:
              'Xcode carries the bundle id in three build configurations and '
              'Xcode only ever edits the one you have open. Found "$id".',
        );
      }
    });

    test('the user-visible name is the same on both platforms', () {
      expect(manifest, contains('android:label="$displayName"'));
      expect(plistString(infoPlist, 'CFBundleDisplayName'), displayName);
      expect(plistString(infoPlist, 'CFBundleName'), displayName);
    });
  });

  group('one version number', () {
    // The release workflow passes --build-name/--build-number from the git tag.
    // That only reaches the artifact if neither platform hardcodes a version,
    // which is exactly the bug that shipped every Android release as
    // versionCode 1 and made upgrades refuse to install.
    test('android takes its version from Flutter', () {
      expect(gradle, contains('versionCode = flutter.versionCode'));
      expect(gradle, contains('versionName = flutter.versionName'));
    });

    test('ios takes its version from Flutter', () {
      expect(
        plistString(infoPlist, 'CFBundleShortVersionString'),
        r'$(FLUTTER_BUILD_NAME)',
      );
      expect(
        plistString(infoPlist, 'CFBundleVersion'),
        r'$(FLUTTER_BUILD_NUMBER)',
      );
      expect(
        pbxproj,
        contains(r'CURRENT_PROJECT_VERSION = "$(FLUTTER_BUILD_NUMBER)"'),
      );
    });

    test('pubspec is the only place a literal version appears', () {
      expect(
        RegExp(
          r'^version: \d+\.\d+\.\d+\+\d+$',
          multiLine: true,
        ).hasMatch(pubspec),
        isTrue,
      );
    });
  });

  group('minimum OS', () {
    test('every iOS floor agrees', () {
      expect(podfile, contains("platform :ios, '$minimumIosVersion'"));

      final targets = RegExp(
        r'IPHONEOS_DEPLOYMENT_TARGET = ([0-9.]+);',
      ).allMatches(pbxproj).map((m) => m.group(1)!).toSet();
      expect(
        targets,
        {minimumIosVersion},
        reason:
            'The Xcode project and the Podfile must declare the same floor, or '
            'CocoaPods resolves against one number and the linker against the '
            'other.',
      );

      // The Podfile's post_install hook pins every pod to the same floor.
      expect(
        podfile,
        contains(
          "config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = "
          "'$minimumIosVersion'",
        ),
      );
    });

    test('the android floor is still what the README promises', () {
      expect(gradle, contains('minSdk = $minimumAndroidSdk'));
    });

    test('no iOS plugin asks for more than the declared floor', () {
      // This is the check that earns its keep over time. flutter_gemma and
      // flutter_onnxruntime both declare `s.platform = :ios, '16.0'` today.
      // The day a `flutter pub upgrade` raises either one, the Podfile is
      // wrong and nothing on a Linux runner would otherwise notice — the
      // failure would surface as a CocoaPods resolution error on somebody's
      // Mac, days later.
      final packageConfig = File('.dart_tool/package_config.json');
      if (!packageConfig.existsSync()) {
        markTestSkipped('run `flutter pub get` first');
        return;
      }
      final packages =
          (jsonDecode(packageConfig.readAsStringSync())
                  as Map<String, dynamic>)['packages']
              as List<dynamic>;

      final declared = <String, String>{};
      for (final package in packages.cast<Map<String, dynamic>>()) {
        final root = Uri.parse(package['rootUri'] as String);
        if (!root.isScheme('file')) continue;
        final podspecs = [
          File('${root.toFilePath()}/ios/${package['name']}.podspec'),
          File('${root.toFilePath()}/darwin/${package['name']}.podspec'),
        ].where((f) => f.existsSync());
        for (final podspec in podspecs) {
          final match = RegExp(
            r"""platform\s*=\s*:ios,\s*['"]([0-9.]+)['"]""",
          ).firstMatch(podspec.readAsStringSync());
          if (match != null) {
            declared[package['name'] as String] = match.group(1)!;
          }
        }
      }

      // A regex that silently matches nothing would make this test pass
      // forever. Anchor it to the two plugins that set the floor today.
      expect(
        declared.keys,
        containsAll(<String>['flutter_gemma', 'flutter_onnxruntime']),
        reason: 'the podspec scan found nothing — the layout changed',
      );

      final floor = double.parse(minimumIosVersion);
      declared.forEach((name, version) {
        expect(
          double.parse(version) <= floor,
          isTrue,
          reason:
              '$name needs iOS $version but ios/Podfile declares '
              '$minimumIosVersion. Raise the floor in ios/Podfile, in '
              'IPHONEOS_DEPLOYMENT_TARGET, and in minimumIosVersion here — '
              'then say so in the README, because it drops devices.',
        );
      });
    });
  });

  group('network posture', () {
    test('cleartext is refused on both platforms', () {
      expect(manifest, contains('android:usesCleartextTraffic="false"'));
      // App Transport Security blocks cleartext by default, so iOS parity is
      // the *absence* of an exception. DownloadService also rejects any
      // non-https URL in Dart; this is the second lock on the same door.
      expect(
        infoPlist.contains('NSAppTransportSecurity'),
        isFalse,
        reason:
            'An ATS exception would let the manifest — the file that carries '
            'the model checksum — be fetched in the clear on iOS only.',
      );
    });

    test('neither platform asks for storage permissions it does not use', () {
      expect(manifest.contains('WRITE_EXTERNAL_STORAGE'), isFalse);
      expect(manifest.contains('READ_EXTERNAL_STORAGE'), isFalse);
      // The iOS equivalents are usage-description strings. The app touches no
      // camera, microphone, contacts or location, so none should be present:
      // an unused NSXxxUsageDescription is a review rejection.
      for (final key in const [
        'NSCameraUsageDescription',
        'NSMicrophoneUsageDescription',
        'NSContactsUsageDescription',
        'NSLocationWhenInUseUsageDescription',
        'NSPhotoLibraryUsageDescription',
      ]) {
        expect(infoPlist.contains(key), isFalse, reason: '$key is unused');
      }
    });
  });

  group('the corpus stays off the network backup', () {
    test('android switches backup off wholesale', () {
      expect(manifest, contains('android:allowBackup="false"'));
      expect(manifest, contains('android:fullBackupContent="false"'));
    });

    test('ios excludes the large directories one by one', () {
      // iOS has no allowBackup switch, so the equivalent is a method channel
      // the three writing services call. If any of them stops calling it, a
      // ~500 MB model starts going to iCloud again.
      expect(appDelegate, contains(PlatformStorage.channelName));
      expect(appDelegate, contains('isExcludedFromBackup'));
      for (final service in const [
        'lib/services/download_service.dart',
        'lib/services/sync_service.dart',
        'lib/services/database_service.dart',
      ]) {
        expect(
          File(service).readAsStringSync(),
          contains('PlatformStorage.excludeFromBackup'),
          reason: '$service writes to Documents and must mark what it writes',
        );
      }
    });
  });

  group('the device envelope', () {
    test('both platforms are arm64 only', () {
      expect(gradle, contains('abiFilters += listOf("arm64-v8a")'));
      expect(infoPlist, contains('UIRequiredDeviceCapabilities'));
      expect(
        RegExp(
          r'<key>UIRequiredDeviceCapabilities</key>\s*<array>\s*<string>arm64</string>',
        ).hasMatch(infoPlist),
        isTrue,
      );
    });

    test('both platforms ask the OS for memory headroom', () {
      expect(manifest, contains('android:largeHeap="true"'));
      expect(
        entitlements,
        contains('com.apple.developer.kernel.increased-memory-limit'),
      );
      expect(
        entitlements,
        contains('com.apple.developer.kernel.extended-virtual-addressing'),
      );
      // An entitlements file that no build configuration points at is a file
      // that does nothing. All three configurations must reference it.
      expect(
        RegExp(
          r'CODE_SIGN_ENTITLEMENTS = Runner/Runner\.entitlements;',
        ).allMatches(pbxproj).length,
        3,
        reason: 'Debug, Release and Profile each need the entitlements path.',
      );
    });

    test('the iOS sideload path exists, like adb push on Android', () {
      expect(plistIsTrue(infoPlist, 'UIFileSharingEnabled'), isTrue);
      expect(
        plistIsTrue(infoPlist, 'LSSupportsOpeningDocumentsInPlace'),
        isTrue,
      );
    });
  });

  group('shared assets', () {
    test(
      'everything the app ships is declared in pubspec, not per platform',
      () {
        // Flutter bundles `flutter: assets:` into both the APK and the IPA. A
        // file copied into android/app/src/main/assets or into the Xcode project
        // would exist on one platform only — and the retrieval index is exactly
        // the kind of artefact somebody would be tempted to add that way.
        expect(Directory('android/app/src/main/assets').existsSync(), isFalse);
        for (final asset in const [
          'assets/index/corpus.json',
          'assets/index/passages.f32',
          'assets/index/passages.f32.json',
          'assets/index/tokenizer.bin',
        ]) {
          expect(pubspec, contains(asset));
          expect(
            pbxproj.contains(asset),
            isFalse,
            reason: '$asset must be bundled by Flutter, not by Xcode',
          );
        }
      },
    );
  });
}
