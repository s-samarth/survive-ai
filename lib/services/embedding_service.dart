import 'dart:math';
import 'dart:typed_data';

/// The no-op embedder: the base class, and the state a build is in before the
/// encoder has been downloaded.
///
/// [isEnabled] is false here, so [RagService] skips the dense leg entirely —
/// no vector is allocated and no similarity loop runs on the hot query path.
/// The app still answers, on its two lexical legs, which is why a missing
/// encoder is a degradation and not an outage.
///
/// The working implementation is [OnnxEmbeddingService], which runs
/// EmbeddingGemma-300m over the query alone; the corpus is embedded offline
/// and ships as vectors. Anything that reads a vector must go through
/// [dimensions] rather than assuming [dims], because the stride used to read
/// the `chunks.embedding` BLOB has to match the model that wrote it.
class EmbeddingService {
  /// Width of an EmbeddingGemma vector, and the default stride.
  static const int dims = 768;

  /// Flip to true only together with a real embedding backend.
  bool get isEnabled => false;

  /// Width of the vectors this embedder produces.
  int get dimensions => dims;

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
