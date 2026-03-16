import 'dart:math';
import 'dart:typed_data';

/// Stub embedding service — always returns empty results so RagService
/// uses pure BM25 (FTS5) retrieval.
///
/// On a 4 GB device, any additional native ML runtime (TFLite, MediaPipe
/// tasks-text) consumes memory alongside the 1.6 GB Gemma model and causes
/// OOM before Gemma even finishes loading. BM25 with field-weighted FTS5
/// is robust and sufficient for keyword-heavy survival queries.
class EmbeddingService {
  static const int dims = 100;

  Future<Float32List> embedQuery(String text) async => Float32List(dims);

  Future<List<Float32List>> embedBatch(List<String> texts) async => [];

  static double cosine(Float32List a, Float32List b) {
    assert(a.length == b.length, 'Embedding dimension mismatch');
    double dot = 0, nA = 0, nB = 0;
    for (var i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      nA += a[i] * a[i];
      nB += b[i] * b[i];
    }
    final denom = sqrt(nA) * sqrt(nB);
    return denom == 0.0 ? 0.0 : dot / denom;
  }

  static bool isComputed(Float32List v) {
    for (final x in v) {
      if (x != 0.0) return true;
    }
    return false;
  }
}
