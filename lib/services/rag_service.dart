import '../models/doc_chunk.dart';
import 'database_service.dart';

/// Orchestrates RAG retrieval: BM25 search → rank → return top-K chunks.
///
/// Phase 1: BM25 only (SQLite FTS5).
/// Phase 2: Add vector search + RRF re-ranking (sqlite-vec + ONNX embedding).
class RagService {
  final DatabaseService _db;

  const RagService(this._db);

  /// Retrieve the most relevant [topK] doc chunks for [query].
  ///
  /// [topicFilter] — optional topic to restrict search (e.g. 'medical').
  Future<List<DocChunk>> retrieve(
    String query, {
    int topK = 4,
    String? topicFilter,
  }) async {
    final ids = await _db.searchFts(query, topicFilter: topicFilter, limit: topK);
    return _db.getChunksByIds(ids);
  }

  /// Retrieve chunks relevant to a multi-topic situation.
  ///
  /// Used by the agentic features: passes all relevant topics from [Situation].
  Future<List<DocChunk>> retrieveForSituation(
    String query,
    List<String> topics, {
    int topK = 6,
  }) async {
    // Query once per topic and merge, then deduplicate by chunk id
    final seen = <String>{};
    final results = <DocChunk>[];

    for (final topic in topics) {
      final chunks = await retrieve(query, topicFilter: topic, topK: topK ~/ topics.length + 1);
      for (final chunk in chunks) {
        if (seen.add(chunk.id)) {
          results.add(chunk);
        }
      }
    }

    return results.take(topK).toList();
  }
}
