import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

/// The passage vectors computed offline and shipped with the app.
///
/// Reading a flat `float32` file rather than numbers in JSON is not a
/// micro-optimisation: 201 x 768 values as JSON text is roughly 3 MB and a
/// second of parsing at launch, against a 603 KB read and no parsing at all.
///
/// The manifest beside it names the model, the dimension and the passage ids
/// in order. Those ids are the whole point: a vector file built against a
/// different chunking would still load, still have plausible dimensions, and
/// pair every passage with a stranger's embedding. There is no symptom for
/// that other than retrieval being mysteriously bad, so the pairing is checked
/// rather than assumed.
class VectorIndex {
  const VectorIndex({
    required this.model,
    required this.dimensions,
    required this.queryPrefix,
    required this.vectors,
  });

  static const String vectorAsset = 'assets/index/passages.f32';
  static const String manifestAsset = 'assets/index/passages.f32.json';

  /// Model key the vectors were produced with, e.g. `embeddinggemma`.
  final String model;
  final int dimensions;

  /// The task prefix the query must carry to land in this same space.
  /// EmbeddingGemma is trained with asymmetric prefixes and loses real
  /// accuracy without them, so it travels with the vectors rather than being
  /// retyped at the call site.
  final String queryPrefix;

  /// Passage chunk id to its vector.
  final Map<String, Float32List> vectors;

  int get length => vectors.length;

  /// Load the shipped vectors, or null when they are absent or inconsistent.
  ///
  /// Null is a degradation, not a failure: [RagService] drops the dense leg and
  /// answers on its two lexical legs.
  static Future<VectorIndex?> load({
    Future<ByteData> Function(String key)? readBinary,
    Future<String> Function(String key)? readString,
  }) async {
    final loadBinary = readBinary ?? rootBundle.load;
    final loadString = readString ?? rootBundle.loadString;
    try {
      final manifest =
          json.decode(await loadString(manifestAsset)) as Map<String, dynamic>;
      final ids = (manifest['ids'] as List<dynamic>).cast<String>();
      final dimensions = manifest['dim'] as int;
      final bytes = await loadBinary(vectorAsset);

      final expected = ids.length * dimensions * 4;
      if (bytes.lengthInBytes != expected) {
        throw StateError(
          'vector file is ${bytes.lengthInBytes} bytes, expected $expected '
          'for ${ids.length} passages of $dimensions dimensions',
        );
      }

      final floats = Float32List.sublistView(bytes);
      final vectors = <String, Float32List>{};
      for (var i = 0; i < ids.length; i++) {
        vectors[ids[i]] = Float32List.sublistView(
          floats,
          i * dimensions,
          (i + 1) * dimensions,
        );
      }
      return VectorIndex(
        model: manifest['model'] as String,
        dimensions: dimensions,
        queryPrefix: manifest['query_prefix'] as String? ?? '',
        vectors: vectors,
      );
    } catch (error) {
      debugPrint('Passage vectors unavailable, dense leg disabled: $error');
      return null;
    }
  }
}
