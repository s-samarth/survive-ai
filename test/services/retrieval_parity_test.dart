import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:survive_ai/services/database_service.dart';
import 'package:survive_ai/services/embedding/vector_index.dart';
import 'package:survive_ai/services/embedding_service.dart';
import 'package:survive_ai/services/index_loader_service.dart';
import 'package:survive_ai/services/rag_service.dart';

/// An embedder that replays vectors Python computed, keyed by query.
///
/// Standing in for the ONNX call is the point. It needs a device, and it is
/// the one part of the pipeline already proven separately: the exported graph
/// agrees with PyTorch, and the Dart tokenizer agrees id-for-id with the
/// Python one that produced these vectors. What is left unproven is everything
/// around it — prefixes, vector loading, cosine, RRF weights, transliteration
/// routing, FTS — and that is what this exercises.
class _ReplayEmbedder extends EmbeddingService {
  _ReplayEmbedder(this._vectors);

  final Map<String, Float32List> _vectors;

  @override
  bool get isEnabled => true;

  @override
  Future<Float32List> embedQuery(String text) async =>
      _vectors[text] ?? Float32List(0);
}

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  final fixture = File('test/fixtures/retrieval_parity.json');
  final vectorFile = File('test/fixtures/query_vectors.f32');

  test(
    'the Dart retriever reproduces the lab, exactly where it can',
    () async {
      // The app is a second implementation of a pipeline that was measured in
      // Python — same chunks, same vectors, same fusion, different language.
      // Every way the two can disagree is silent: a retyped RRF weight, a
      // missing task prefix, a transliterated query that reaches the dense leg
      // anyway. None of them throw; they just make the device worse than the
      // report, which is the one failure an eval cannot see by construction.
      //
      // Ranking equality is asserted rather than recall. Two implementations
      // can reach the same recall through different rankings, which would hide
      // exactly this drift; equal rankings imply equal scores on every metric.
      if (!fixture.existsSync() || !vectorFile.existsSync()) {
        markTestSkipped('run `python -m evals parity` to build the fixture');
        return;
      }

      final decoded =
          json.decode(fixture.readAsStringSync()) as Map<String, dynamic>;
      final cases = (decoded['cases'] as List).cast<Map<String, dynamic>>();
      final dimensions = decoded['dim'] as int;

      final floats = Float32List.sublistView(
        ByteData.sublistView(vectorFile.readAsBytesSync()),
      );
      expect(
        floats.length,
        cases.length * dimensions,
        reason: 'query vectors do not match the case list they were built with',
      );
      final vectors = <String, Float32List>{
        for (var i = 0; i < cases.length; i++)
          cases[i]['query'] as String: Float32List.sublistView(
            floats,
            i * dimensions,
            (i + 1) * dimensions,
          ),
      };

      final scratch = Directory.systemTemp.createTempSync('survive_ai_parity');
      addTearDown(() => scratch.deleteSync(recursive: true));
      final db = DatabaseService(databasePath: '${scratch.path}/parity.db');

      final index = await IndexLoaderService(
        readAsset: (key) async => File(key).readAsString(),
        loadVectors: () => VectorIndex.load(
          readBinary: (key) async =>
              ByteData.sublistView(File(key).readAsBytesSync()),
          readString: (key) async => File(key).readAsString(),
        ),
      ).load();
      expect(index, isNotNull, reason: 'the prebuilt index must be present');

      var withVectors = 0;
      for (final guide in index!.values) {
        await db.insertChunks(guide.passages);
        withVectors += guide.passages.where((c) => c.embedding != null).length;
      }
      expect(
        withVectors,
        greaterThan(0),
        reason: 'no passage carried a vector; the dense leg would be inert',
      );

      final rag = RagService(db, _ReplayEmbedder(vectors));

      final stored = {
        for (final (id, vector) in await db.getAllEmbeddings()) id: vector,
      };

      // 1. The dense leg's *scores* must match. Scores, not ranks: cosines
      //    over one corpus cluster tightly enough that the 1e-7 gap between
      //    numpy's float64 dot product and Dart's accumulation reorders
      //    near-ties, so an ordering assertion would fail on arithmetic that
      //    is correct. The score is the quantity actually being reproduced,
      //    and it is what the fusion consumes.
      final denseDivergent = <String>[];
      var worstDelta = 0.0;
      var agreed = 0;
      var compared = 0;

      for (final entry in cases) {
        final query = entry['query'] as String;
        final vector = vectors[query]!;
        for (final pair in (entry['dense_scores'] as List)) {
          final id = (pair as List)[0] as String;
          final expectedScore = (pair[1] as num).toDouble();
          final vec = stored[id];
          if (vec == null) {
            denseDivergent.add('${entry['id']}  $id is not in the database');
            continue;
          }
          final actual = EmbeddingService.cosine(vector, vec);
          final delta = (actual - expectedScore).abs();
          if (delta > worstDelta) worstDelta = delta;
          // 1e-5 against a measured worst case of 6e-7: sixteen times the
          // observed float noise, and still four orders of magnitude below
          // any real defect. A missing task prefix moves a score by ~0.05; a
          // mispaired vector moves it by ~0.5.
          if (delta > 1e-5) {
            denseDivergent.add('${entry['id']}  $query -> $id\n'
                '    python: $expectedScore\n'
                '    dart:   $actual');
          }
        }

        // 2. The fused ranking cannot match exactly — the lexical legs are
        //    FTS5's bm25() here and Okapi BM25 there. Overlap is asserted
        //    instead, which still catches a missing task prefix, a retyped RRF
        //    weight, or a transliterated query reaching the dense leg.
        final expected = (entry['expected'] as List).cast<String>();
        if (expected.isEmpty) continue;
        final actual = (await rag.retrieve(query, topK: expected.length))
            .map((c) => c.id)
            .toSet();
        agreed += expected.where(actual.contains).length;
        compared += expected.length;
      }

      expect(
        denseDivergent,
        isEmpty,
        reason:
            '${denseDivergent.length} dense scores differ from the lab by more '
            'than 1e-5:\n${denseDivergent.take(5).join('\n')}',
      );
      // ignore: avoid_print
      print('worst dense score delta vs the lab: '
          '${worstDelta.toStringAsExponential(2)}');

      final overlap = agreed / compared;
      expect(
        overlap,
        greaterThan(0.6),
        reason:
            'only ${(overlap * 100).toStringAsFixed(1)}% of the lab\'s top-5 '
            'passages appear in the app\'s top-5; the two pipelines have '
            'diverged beyond what different BM25 implementations explain',
      );
      // ignore: avoid_print
      print('fused top-5 agreement with the lab: '
          '${(overlap * 100).toStringAsFixed(1)}%');
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
