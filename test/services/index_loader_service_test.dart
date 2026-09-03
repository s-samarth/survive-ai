import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:survive_ai/services/index_loader_service.dart';

Future<String> _throwMissing(String key) =>
    Future.error(FlutterError('asset not bundled'));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Map<String, dynamic> artifact({int schema = 2}) => {
    'schema': schema,
    'children': [
      {
        'chunk_id': 'bites#p3#do-not-apply-a-tourniquet',
        'topic': 'bites',
        'heading_path': 'Snakebite > What NOT To Do',
        'text': 'DO NOT apply a tourniquet.',
        'ordinal': 0,
        'line_start': 66,
        'line_end': 66,
        'is_prohibition': true,
      },
      {
        'chunk_id': 'bites#p3#do-not-cut-the-bite',
        'topic': 'bites',
        'heading_path': 'Snakebite > What NOT To Do',
        'text': 'DO NOT cut the bite site.',
        'ordinal': 1,
        'line_start': 67,
        'line_end': 67,
        'is_prohibition': true,
      },
    ],
    'passages': [
      {
        'passage_id': 'bites#p3::w0',
        'parent_id': 'bites#p3',
        'topic': 'bites',
        'heading_path': 'Snakebite > What NOT To Do',
        'child_ids': [
          'bites#p3#do-not-apply-a-tourniquet',
          'bites#p3#do-not-cut-the-bite',
        ],
      },
    ],
    'parents': [],
  };

  IndexLoaderService loaderFor(Map<String, dynamic> payload) =>
      IndexLoaderService(readAsset: (_) async => json.encode(payload));

  test('rebuilds passage bodies from their children', () {
    // Only children carry text in the artifact; storing all three verbatim
    // tripled a file that ships inside the APK.
    return loaderFor(artifact()).load().then((index) {
      final guide = index!['bites']!;
      expect(guide.passages, hasLength(1));
      expect(guide.passages.first.body, contains('apply a tourniquet'));
      expect(guide.passages.first.body, contains('cut the bite site'));
    });
  });

  test('keeps every child as a citation target', () async {
    final index = await loaderFor(artifact()).load();
    final guide = index!['bites']!;

    expect(guide.citations, hasLength(2));
    expect(guide.citations.first.chunkId, 'bites#p3::w0');
    expect(guide.citations.every((c) => c.isProhibition), isTrue);
    expect(guide.citations.first.lineStart, 66);
  });

  test('citations are attributed to the guide document', () async {
    final index = await loaderFor(artifact()).load();
    expect(index!['bites']!.citations.first.docId, 'bites_guide');
  });

  test('an unrecognised schema falls back rather than misreading', () async {
    // A newer artifact must not be parsed on guesses.
    expect(await loaderFor(artifact(schema: 99)).load(), isNull);
  });

  test('a missing artifact falls back to runtime chunking', () async {
    const absent = IndexLoaderService(readAsset: _throwMissing);
    expect(await absent.load(), isNull);
  });

  test('the artifact actually committed to the repo loads', () async {
    // An integration check: the unit tests above use a fixture, so nothing
    // else would notice if the exported file drifted from what this parses.
    final raw = File('assets/index/corpus.json').readAsStringSync();
    final index = await IndexLoaderService(readAsset: (_) async => raw).load();

    expect(index, isNotNull);
    expect(index!.length, greaterThanOrEqualTo(18));
    expect(index['bites']!.passages, isNotEmpty);
    expect(index['bites']!.citations, isNotEmpty);
    expect(
      index.values.expand((g) => g.citations).where((c) => c.isProhibition),
      isNotEmpty,
    );
  });
}
