import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:survive_ai/models/doc_manifest.dart';
import 'package:survive_ai/models/doc_topic.dart';
import 'package:survive_ai/services/embedding/encoder_download.dart';
import 'package:survive_ai/services/llm_service.dart';
import 'package:survive_ai/services/network_policy.dart';
import 'package:survive_ai/services/sync_service.dart';

/// `manifest.json` is fetched by every install from `main`. It is data, not
/// code, so nothing else would notice it drifting from the guides it lists or
/// the model the app expects — until a phone downloaded the wrong thing.
void main() {
  final manifest = DocManifest.fromJson(
    jsonDecode(File('manifest.json').readAsStringSync())
        as Map<String, dynamic>,
  );

  test('the app fetches this file', () {
    expect(
      kManifestUrl,
      'https://raw.githubusercontent.com/s-samarth/survive-ai/main/manifest.json',
    );
  });

  group('guides', () {
    test('one entry per topic', () {
      expect(
        manifest.docs.map((d) => d.topic).toSet(),
        DocTopic.values.map((t) => t.key).toSet(),
      );
      expect(manifest.docs, hasLength(DocTopic.values.length));
    });

    for (final topic in DocTopic.values) {
      test(topic.key, () {
        final entry = manifest.docs.firstWhere((d) => d.topic == topic.key);
        expect(entry.id, topic.docId);
        expect(entry.filename, '${topic.key}.md');
        expect(entry.url, endsWith('/main/${topic.assetPath}'));
        // A version other than the bundled one makes every install replace
        // the offline-built index with runtime chunks. Bump both together.
        expect(entry.version, SyncService.bundledVersion);
        final bytes = File(topic.assetPath).readAsBytesSync();
        expect(
          entry.sha256,
          sha256.convert(bytes).toString(),
          reason: 'The guide changed; update its sha256 in manifest.json.',
        );
      });
    }
  });

  test('model entry is the file the app loads, pinned', () {
    expect(manifest.model.name, kModelName);
    expect(manifest.model.sha256, matches(RegExp(r'^[0-9a-f]{64}$')));
    expect(manifest.model.url, isNot(contains('/resolve/main/')));
  });

  test('encoder entries match the compiled-in fallback', () {
    expect(manifest.embedder, hasLength(EncoderDownload.fallback.length));
    for (var i = 0; i < manifest.embedder.length; i++) {
      final remote = manifest.embedder[i];
      final local = EncoderDownload.fallback[i];
      expect(remote.name, local.name);
      expect(remote.url, local.url);
      expect(remote.sizeBytes, local.sizeBytes);
      expect(remote.sha256, local.sha256);
    }
  });

  group('NetworkPolicy', () {
    test('Wi-Fi and ethernet are allowed', () {
      expect(NetworkPolicy.allows([ConnectivityResult.wifi]), isTrue);
      expect(NetworkPolicy.allows([ConnectivityResult.ethernet]), isTrue);
      expect(
        NetworkPolicy.allows([
          ConnectivityResult.mobile,
          ConnectivityResult.wifi,
        ]),
        isTrue,
      );
    });

    test('mobile data alone is not', () {
      expect(NetworkPolicy.allows([ConnectivityResult.mobile]), isFalse);
      expect(NetworkPolicy.allows([ConnectivityResult.vpn]), isFalse);
      expect(NetworkPolicy.allows([ConnectivityResult.none]), isFalse);
      expect(NetworkPolicy.allows([]), isFalse);
    });
  });
}
