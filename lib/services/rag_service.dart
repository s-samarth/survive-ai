import 'dart:typed_data';
import '../models/doc_chunk.dart';
import '../utils/query_expander.dart';
import 'database_service.dart';
import 'embedding_service.dart';

/// Orchestrates hybrid RAG retrieval with three independent signals merged
/// via Reciprocal Rank Fusion (RRF):
///
///   1. **BM25 (exact)** — FTS5 on the original query. Fast, precise for
///      exact keywords.
///   2. **BM25 (expanded)** — FTS5 on a synonym-expanded query. Bridges
///      vocabulary gaps (e.g. "bleeding" → "hemorrhage wound tourniquet").
///   3. **Dense (embedding)** — cosine similarity on vector embeddings.
///      Currently stubbed (returns empty); when enabled, captures deep
///      semantic similarity beyond word overlap.
///
/// RRF merges all non-empty ranked lists into a single final ranking.
/// If only one signal produces results, it degrades gracefully to that
/// signal alone — no crash or error.
class RagService {
  final DatabaseService _db;
  final EmbeddingService _embedder;

  /// RRF constant K=60 (standard value from the original RRF paper).
  static const int _rrfK = 60;

  /// Number of candidates oversampled from each retrieval leg before RRF merge.
  static const int _candidateLimit = 20;

  const RagService(this._db, this._embedder);

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Retrieve the most relevant [topK] doc chunks for [query].
  ///
  /// Runs three retrieval legs in parallel, then merges via RRF.
  /// [topicFilter] — optional topic to restrict search (e.g. 'medical').
  Future<List<DocChunk>> retrieve(
    String query, {
    int topK = 4,
    String? topicFilter,
  }) async {
    // Leg 1: BM25 on original query (exact keyword matching)
    final bm25Future = _db.searchFts(
      query,
      topicFilter: topicFilter,
      limit: _candidateLimit,
    );

    // Leg 2: BM25 on expanded query (synonym/related term matching)
    final expandedQuery = QueryExpander.expand(query);
    final semanticFuture = expandedQuery != query
        ? _db.searchFts(
            expandedQuery,
            topicFilter: topicFilter,
            limit: _candidateLimit,
          )
        : Future.value(<String>[]);

    // Leg 3: Dense embedding retrieval. Skipped entirely while the embedding
    // backend is disabled — no vector allocated, no similarity scan.
    final denseIds = _embedder.isEnabled
        ? await _denseRetrieve(
            await _embedder.embedQuery(query),
            topicFilter: topicFilter,
          )
        : const <String>[];

    final bm25Ids = await bm25Future;
    final semanticIds = await semanticFuture;

    // 3-way RRF merge
    final topIds = _rrfMerge(
      rankedLists: [bm25Ids, semanticIds, denseIds],
      topK: topK,
    );

    return _db.getChunksByIds(topIds);
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  /// Brute-force cosine similarity against all stored embeddings.
  ///
  /// The corpus is at most ~300 chunks — O(300 × dims) is sub-millisecond on
  /// ARM. No approximate nearest-neighbour index is needed.
  ///
  /// Returns an empty list if no embeddings have been computed yet.
  Future<List<String>> _denseRetrieve(
    Float32List queryVec, {
    String? topicFilter,
  }) async {
    if (queryVec.isEmpty) return const [];

    final allEmbeddings = await _db.getAllEmbeddings(topicFilter: topicFilter);
    if (allEmbeddings.isEmpty) return [];

    final scored = allEmbeddings.map((entry) {
      final (id, vec) = entry;
      return (id, EmbeddingService.cosine(queryVec, vec));
    }).toList()..sort((a, b) => b.$2.compareTo(a.$2));

    return scored.take(_candidateLimit).map((e) => e.$1).toList();
  }

  /// Merge N ranked ID lists using Reciprocal Rank Fusion.
  ///
  ///   score(d) = Σ_i  1 / (rank(d, list_i) + K)
  ///
  /// Empty lists are silently skipped — the RRF gracefully degrades to
  /// whichever signals are available.
  List<String> _rrfMerge({
    required List<List<String>> rankedLists,
    required int topK,
  }) {
    final scores = <String, double>{};

    for (final list in rankedLists) {
      for (var i = 0; i < list.length; i++) {
        final id = list[i];
        scores[id] = (scores[id] ?? 0.0) + 1.0 / (i + 1 + _rrfK);
      }
    }

    final sorted = scores.keys.toList()
      ..sort((a, b) => scores[b]!.compareTo(scores[a]!));

    return sorted.take(topK).toList();
  }
}
