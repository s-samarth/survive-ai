import 'dart:math';
import 'dart:typed_data';

/// Dense-retrieval hook, currently disabled.
///
/// [isEnabled] is false, so [embedQuery] and [embedBatch] return empty results
/// and [RagService] skips the dense leg entirely — no vector is allocated and
/// no similarity loop runs on the hot query path. (The previous stub allocated
/// a 100-float zero vector per query and then scanned it to discover it was
/// zero.)
///
/// Why disabled: a second native ML runtime alongside the Gemma weights does
/// not fit in the memory budget on a 4-6 GB device. [QueryExpander] covers the
/// vocabulary gap that dense retrieval would otherwise close, at zero memory
/// cost. The plumbing stays so that enabling a small quantised embedding model
/// (EmbeddingGemma-300m runs in under 200 MB) is a one-flag change.
class EmbeddingService {
  /// Embedding width, used when [isEnabled] becomes true. Must match the
  /// stride used to read the `chunks.embedding` BLOB.
  static const int dims = 768;

  /// Flip to true only together with a real embedding backend.
  bool get isEnabled => false;

  Future<Float32List> embedQuery(String text) async => Float32List(0);

  Future<List<Float32List>> embedBatch(List<String> texts) async => const [];

  /// Cosine similarity between two equal-length vectors.
  static double cosine(Float32List a, Float32List b) {
    if (a.length != b.length || a.isEmpty) return 0.0;
    double dot = 0, nA = 0, nB = 0;
    for (var i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      nA += a[i] * a[i];
      nB += b[i] * b[i];
    }
    final denom = sqrt(nA) * sqrt(nB);
    return denom == 0.0 ? 0.0 : dot / denom;
  }
}
