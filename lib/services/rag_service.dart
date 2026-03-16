import 'dart:typed_data';
import '../models/doc_chunk.dart';
import 'database_service.dart';
import 'embedding_service.dart';

/// Orchestrates hybrid RAG retrieval: BM25 + dense (TFLite USE-Lite) with
/// Reciprocal Rank Fusion (RRF) merge.
///
/// BM25 is fast and precise for exact keywords.
/// Dense retrieval handles semantic reformulations (e.g. "I'm bleeding"
/// matching "wound care / hemorrhage control").
/// RRF merges both ranked lists into a single final ranking.
///
/// Graceful degradation: if embeddings have not been computed yet (first
/// launch before seeding finishes), dense retrieval returns no results and
/// the RRF reduces to pure BM25 automatically — no crash or error.
class RagService {
  final DatabaseService _db;
  final EmbeddingService _embedder;

  /// RRF constant K=60 (standard value from the original RRF paper).
  /// Higher K reduces the influence of top-ranked results; lower K amplifies it.
  static const int _rrfK = 60;

  /// Number of candidates oversampled from each retrieval leg before RRF merge.
  static const int _candidateLimit = 20;

  const RagService(this._db, this._embedder);

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Retrieve the most relevant [topK] doc chunks for [query].
  ///
  /// Runs BM25 and dense retrieval, then merges via RRF.
  /// [topicFilter] — optional topic to restrict search (e.g. 'medical').
  Future<List<DocChunk>> retrieve(
    String query, {
    int topK = 4,
    String? topicFilter,
  }) async {
    // Kick off BM25 immediately (no async dependency)
    final bm25Future = _db.searchFts(
      query,
      topicFilter: topicFilter,
      limit: _candidateLimit,
    );

    // Dense: embed query (loads TFLite, runs inference, disposes interpreter)
    final queryVec = await _embedder.embedQuery(query);
    final bm25Ids = await bm25Future;

    final denseIds = await _denseRetrieveWithVector(
      queryVec,
      topicFilter: topicFilter,
    );

    final topIds = _rrfMerge(
      bm25Ids: bm25Ids,
      denseIds: denseIds,
      topK: topK,
    );

    return _db.getChunksByIds(topIds);
  }

  /// Retrieve chunks relevant to multiple topics simultaneously.
  ///
  /// Embeds the query once, then runs dense + BM25 per topic and merges
  /// results with deduplication. The query vector is reused across topics
  /// to avoid repeated TFLite model loads.
  Future<List<DocChunk>> retrieveForSituation(
    String query,
    List<String> topics, {
    int topK = 6,
  }) async {
    // Embed once — reuse vector across all topic queries
    final queryVec = await _embedder.embedQuery(query);

    final seen = <String>{};
    final scores = <String, double>{};

    for (final topic in topics) {
      final perTopicK = topK ~/ topics.length + 1;

      final bm25Ids = await _db.searchFts(
        query,
        topicFilter: topic,
        limit: _candidateLimit,
      );
      final denseIds = await _denseRetrieveWithVector(
        queryVec,
        topicFilter: topic,
      );

      // Accumulate RRF scores across topics (cross-topic re-ranking)
      final topicMerge = _rrfMerge(
        bm25Ids: bm25Ids,
        denseIds: denseIds,
        topK: perTopicK,
      );

      for (var rank = 0; rank < topicMerge.length; rank++) {
        final id = topicMerge[rank];
        if (seen.add(id)) {
          scores[id] = (scores[id] ?? 0.0) + 1.0 / (rank + 1 + _rrfK);
        }
      }
    }

    // Sort deduplicated results by accumulated RRF score
    final sortedIds = scores.keys.toList()
      ..sort((a, b) => scores[b]!.compareTo(scores[a]!));

    return _db.getChunksByIds(sortedIds.take(topK).toList());
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  /// Brute-force cosine similarity against all stored embeddings.
  ///
  /// The corpus is at most ~300 chunks — O(300 × 512) is sub-millisecond on
  /// ARM. No approximate nearest-neighbour index is needed.
  ///
  /// Returns empty list if no embeddings have been computed yet (before the
  /// embedding pass runs after first seeding).
  Future<List<String>> _denseRetrieveWithVector(
    Float32List queryVec, {
    String? topicFilter,
  }) async {
    // If query is the zero vector, embedder returned fallback — skip dense leg
    if (!EmbeddingService.isComputed(queryVec)) return [];

    final allEmbeddings = await _db.getAllEmbeddings(topicFilter: topicFilter);
    if (allEmbeddings.isEmpty) return [];

    final scored = allEmbeddings.map((entry) {
      final (id, vec) = entry;
      return (id, EmbeddingService.cosine(queryVec, vec));
    }).toList()
      ..sort((a, b) => b.$2.compareTo(a.$2));

    return scored.take(_candidateLimit).map((e) => e.$1).toList();
  }

  /// Merge two ranked ID lists using Reciprocal Rank Fusion.
  ///
  ///   score(d) = Σ 1 / (rank(d, list_i) + K)
  ///
  /// A chunk that appears at rank 1 in both lists scores ~2/(1+60) ≈ 0.033,
  /// well above a chunk that only appears in one list at rank 5 (≈ 0.015).
  List<String> _rrfMerge({
    required List<String> bm25Ids,
    required List<String> denseIds,
    required int topK,
  }) {
    final scores = <String, double>{};

    for (var i = 0; i < bm25Ids.length; i++) {
      final id = bm25Ids[i];
      scores[id] = (scores[id] ?? 0.0) + 1.0 / (i + 1 + _rrfK);
    }

    for (var i = 0; i < denseIds.length; i++) {
      final id = denseIds[i];
      scores[id] = (scores[id] ?? 0.0) + 1.0 / (i + 1 + _rrfK);
    }

    final sorted = scores.keys.toList()
      ..sort((a, b) => scores[b]!.compareTo(scores[a]!));

    return sorted.take(topK).toList();
  }
}
