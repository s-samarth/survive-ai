import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:survive_ai/services/embedding/vector_index.dart';

ByteData _vectorBytes(List<List<double>> rows) {
  final flat = Float32List.fromList([for (final row in rows) ...row]);
  return ByteData.sublistView(flat);
}

Future<ByteData> Function(String) _binary(ByteData data) =>
    (_) async => data;

Future<String> Function(String) _text(Map<String, dynamic> manifest) =>
    (_) async => json.encode(manifest);

void main() {
  group('VectorIndex', () {
    test('pairs each vector with the passage id at its position', () async {
      final index = await VectorIndex.load(
        readBinary: _binary(_vectorBytes([
          [1, 0],
          [0, 1],
        ])),
        readString: _text({
          'model': 'embeddinggemma',
          'dim': 2,
          'ids': ['p1', 'p2'],
          'query_prefix': 'task: search result | query: ',
        }),
      );

      expect(index, isNotNull);
      expect(index!.length, 2);
      expect(index.vectors['p1'], [1, 0]);
      expect(index.vectors['p2'], [0, 1]);
      expect(index.queryPrefix, 'task: search result | query: ');
    });

    test('refuses a vector file that does not match its manifest', () async {
      // The failure this guards has no symptom. A vector file built against a
      // different chunking loads, has plausible dimensions, and pairs every
      // passage with a stranger's embedding; retrieval is simply worse, with
      // nothing to point at. Length is the cheapest thing that catches it.
      final index = await VectorIndex.load(
        readBinary: _binary(_vectorBytes([
          [1, 0],
        ])),
        readString: _text({
          'model': 'embeddinggemma',
          'dim': 2,
          'ids': ['p1', 'p2'],
          'query_prefix': '',
        }),
      );

      expect(index, isNull);
    });

    test('a missing artifact degrades rather than throwing', () async {
      final index = await VectorIndex.load(
        readBinary: (_) async => throw Exception('asset not found'),
        readString: (_) async => throw Exception('asset not found'),
      );

      expect(index, isNull);
    });

    test('the shipped vectors match the shipped index', () async {
      // Deliberately reads the real artifacts, not a fixture. The two are
      // built by one command and are only meaningful together, so the thing
      // worth asserting is that what is actually in the repository agrees.
      final vectorFile = File(VectorIndex.vectorAsset);
      final manifestFile = File(VectorIndex.manifestAsset);
      if (!vectorFile.existsSync() || !manifestFile.existsSync()) {
        markTestSkipped('run `python -m survive_rag pack` to build artifacts');
        return;
      }

      final index = await VectorIndex.load(
        readBinary: (key) async =>
            ByteData.sublistView(File(key).readAsBytesSync()),
        readString: (key) async => File(key).readAsString(),
      );

      expect(index, isNotNull);
      expect(index!.dimensions, 768);
      expect(index.model, 'embeddinggemma');
      expect(index.length, greaterThan(100));
      // The task prefix is not decoration: EmbeddingGemma is trained with it,
      // and a query encoded without it lands somewhere else in the space than
      // the documents it is being compared against.
      expect(index.queryPrefix, contains('query:'));

      // Vectors ship L2-normalised, which is what lets cosine be a dot
      // product and what the recorded scores assume.
      for (final vector in index.vectors.values.take(20)) {
        var sum = 0.0;
        for (final value in vector) {
          sum += value * value;
        }
        expect(sum, closeTo(1.0, 1e-3));
      }
    });
  });
}
