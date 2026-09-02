import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:survive_ai/models/doc_topic.dart';

void main() {
  group('DocTopic', () {
    test('every topic has a bundled Markdown guide on disk', () {
      // Guards the failure mode where a topic is added to the enum but the
      // guide is never written: the app would then show an empty situation
      // and RAG would have no chunks for it, silently.
      for (final topic in DocTopic.values) {
        expect(
          File(topic.assetPath).existsSync(),
          isTrue,
          reason: 'Missing guide for ${topic.name}: ${topic.assetPath}',
        );
      }
    });

    test('every bundled guide has non-trivial content', () {
      for (final topic in DocTopic.values) {
        final chars = File(topic.assetPath).readAsStringSync().length;
        expect(
          chars,
          greaterThan(2000),
          reason: '${topic.assetPath} is only $chars chars — likely a stub',
        );
      }
    });

    test('keys are unique, snake_case, and round-trip through fromKey', () {
      final keys = DocTopic.values.map((t) => t.key).toList();
      expect(keys.toSet().length, keys.length, reason: 'duplicate topic key');
      for (final topic in DocTopic.values) {
        expect(topic.key, matches(RegExp(r'^[a-z][a-z_]*$')));
        expect(DocTopic.fromKey(topic.key), topic);
      }
      expect(DocTopic.fromKey('jungle'), isNull); // retired v1 topic
    });

    test('every topic has a display name and a summary', () {
      for (final topic in DocTopic.values) {
        expect(topic.displayName, isNotEmpty);
        expect(topic.summary, isNotEmpty);
      }
    });
  });
}
