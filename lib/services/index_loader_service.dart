import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../models/citation.dart';
import '../models/doc_chunk.dart';
import '../models/doc_topic.dart';
import 'embedding/vector_index.dart';

/// One guide's share of the prebuilt index.
class IndexedGuide {
  const IndexedGuide({required this.passages, required this.citations});

  /// What retrieval scores and what FTS5 indexes.
  final List<DocChunk> passages;

  /// The paragraphs those passages were built from — citation targets.
  final List<Citation> citations;
}

/// Loads the index built offline by the Python indexer.
///
/// The app used to chunk markdown at runtime, which meant chunk ids depended
/// on a Dart implementation that no eval could see. Chunking now happens once
/// at build time and ships as an artifact, so a citation means the same thing
/// in the app, in the guide reader and in an eval report — which is the whole
/// point of having stable ids.
///
/// It also buys the retrieval policy the evals settled on: ~320-token
/// passages with 80-token overlap, worth roughly ten points of Recall@5 over
/// the paragraph-sized chunks the runtime chunker produced, at no cost on the
/// device beyond reading a file.
///
/// Built by `python -m survive_rag chunk --export assets/index/corpus.json`.
class IndexLoaderService {
  const IndexLoaderService({
    Future<String> Function(String key)? readAsset,
    Future<VectorIndex?> Function()? loadVectors,
  }) : _readAsset = readAsset,
       _loadVectors = loadVectors;

  /// How the artifact is read. Injectable so tests can supply a fixture:
  /// mocking the asset channel silently falls through to the real bundle,
  /// and a fixture that happens to resemble the real corpus then passes for
  /// the wrong reason.
  final Future<String> Function(String key)? _readAsset;

  /// How the passage vectors are read. Injectable for the same reason
  /// [_readAsset] is, and separate from the index itself so a missing vector
  /// file degrades the dense leg rather than failing the whole load.
  final Future<VectorIndex?> Function()? _loadVectors;

  static const String assetPath = 'assets/index/corpus.json';

  /// Schema this loader understands. A newer artifact is ignored rather than
  /// misread, and the caller falls back to runtime chunking.
  static const int supportedSchema = 2;

  /// Read the artifact and group it by guide.
  ///
  /// Returns null when the asset is absent or its schema is unrecognised, so
  /// a build without it still works through the runtime chunker.
  Future<Map<String, IndexedGuide>?> load() async {
    try {
      final read = _readAsset ?? rootBundle.loadString;
      final raw = await read(assetPath);
      final vectors = await (_loadVectors ?? VectorIndex.load)();
      final decoded = json.decode(raw) as Map<String, dynamic>;

      if (decoded['schema'] != supportedSchema) {
        debugPrint(
          'Index schema ${decoded['schema']} != $supportedSchema; '
          'falling back to runtime chunking.',
        );
        return null;
      }
      return _group(decoded, vectors);
    } catch (e) {
      debugPrint('No prebuilt index ($e); falling back to runtime chunking.');
      return null;
    }
  }

  /// Join passages to their children and bucket everything by topic.
  ///
  /// Only children carry text in the artifact — passages are id lists — so
  /// the passage body is rebuilt here rather than stored three times.
  Map<String, IndexedGuide> _group(
    Map<String, dynamic> decoded,
    VectorIndex? vectors,
  ) {
    final children = <String, Map<String, dynamic>>{
      for (final c
          in (decoded['children'] as List).cast<Map<String, dynamic>>())
        c['chunk_id'] as String: c,
    };

    final passagesByTopic = <String, List<DocChunk>>{};
    final citationsByTopic = <String, List<Citation>>{};
    final counters = <String, int>{};

    for (final row
        in (decoded['passages'] as List).cast<Map<String, dynamic>>()) {
      final topic = row['topic'] as String;
      final docId = _docIdFor(topic);
      final passageId = row['passage_id'] as String;
      final childIds = (row['child_ids'] as List).cast<String>();

      final bodies = <String>[];
      for (final childId in childIds) {
        final child = children[childId];
        if (child == null) continue;
        bodies.add(child['text'] as String);
        citationsByTopic
            .putIfAbsent(topic, () => [])
            .add(Citation.fromIndex(child, passageId).copyWithDoc(docId));
      }
      if (bodies.isEmpty) continue;

      final index = counters.update(topic, (v) => v + 1, ifAbsent: () => 0);
      passagesByTopic
          .putIfAbsent(topic, () => [])
          .add(
            DocChunk(
              id: passageId,
              docId: docId,
              topic: topic,
              headingPath: row['heading_path'] as String? ?? '',
              body: bodies.join('\n'),
              chunkIndex: index,
              embedding: vectors?.vectors[passageId],
            ),
          );
    }

    return {
      for (final topic in passagesByTopic.keys)
        topic: IndexedGuide(
          passages: passagesByTopic[topic]!,
          citations: citationsByTopic[topic] ?? const [],
        ),
    };
  }

  static String _docIdFor(String topicKey) {
    for (final t in DocTopic.values) {
      if (t.key == topicKey) return t.docId;
    }
    return '${topicKey}_guide';
  }
}
