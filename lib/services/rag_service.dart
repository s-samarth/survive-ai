import 'dart:typed_data';
import '../models/doc_chunk.dart';
import '../utils/query_expander.dart';
import '../utils/query_router.dart';
import 'database_service.dart';
import 'embedding_service.dart';

/// Orchestrates hybrid RAG retrieval with three independent signals merged
/// via Reciprocal Rank Fusion (RRF):
///
///   1. **BM25 (exact)** — FTS5 on the original query. Fast, precise for
///      exact keywords.
///   2. **BM25 (expanded)** — FTS5 on a synonym-expanded query. Bridges
///      vocabulary gaps (e.g. "bleeding" → "hemorrhage wound tourniquet").
///   3. **Dense (embedding)** — cosine similarity against EmbeddingGemma
///      vectors. The corpus is embedded offline and ships with the app; only
///      the query is encoded here. Captures semantic similarity that no amount
///      of word overlap reaches, and is worth roughly nine points of Recall@5.
///
/// RRF merges all non-empty ranked lists into a single final ranking.
/// If only one signal produces results, it degrades gracefully to that
/// signal alone — no crash or error, and a build without the encoder still
/// answers on its two lexical legs.
///
/// The leg weights are not guesses. They are the configuration measured over
/// the 382-case retrieval golden set in `python/`, which reaches Recall@5
/// 90.0% with exactly these numbers; changing one here without rerunning
/// `python -m evals eval --dense` puts the device somewhere the lab has never
/// scored.
class RagService {
  final DatabaseService _db;
  final EmbeddingService _embedder;

  /// RRF constant K=60 (standard value from the original RRF paper).
  static const int _rrfK = 60;

  /// Per-leg RRF weights, mirroring `RetrievalConfig` in `python/`.
  static const double _literalWeight = 1.0;
  static const double _expandedWeight = 0.7;
  static const double _denseWeight = 1.5;

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

    // Leg 3: Dense embedding retrieval. Skipped entirely when the encoder is
    // absent — no vector allocated, no similarity scan — and also skipped for
    // romanised Hindi, which is not a tuning choice but a measured one: on the
    // Hinglish slice the lexical legs alone score 60.7% and every embedding
    // model 28-46%, because they are trained on Devanagari and rate "saanp"
    // barely above noise. Down-weighting rather than dropping still poisons
    // the ranking, so the routing is binary.
    final useDense = _embedder.isEnabled && !QueryRouter.hasBridgeTerms(query);
    final denseIds = useDense
        ? await denseCandidates(
            await _embedder.embedQuery(query),
            topicFilter: topicFilter,
          )
        : const <String>[];

    final bm25Ids = await bm25Future;
    final semanticIds = await semanticFuture;

    final topIds = _rrfMerge(
      rankedLists: [bm25Ids, semanticIds, denseIds],
      weights: const [_literalWeight, _expandedWeight, _denseWeight],
      topK: topK,
    );

    return _db.getChunksByIds(topIds);
  }

  /// Top embedding cosine for [query], or null when this build has no
  /// embedder.
  ///
  /// This is the signal the router declines on. It separates where BM25 does
  /// not: measured over 382 golden-set cases, in-corpus queries score
  /// 0.30-0.70 and out-of-corpus ones 0.09-0.22, while BM25 overlaps
  /// completely.
  ///
  /// Null means *unknown*, which is not the same as zero. A zero was measured
  /// and justifies declining; an unknown must not, because refusing on absent
  /// evidence would turn away emergencies on a build without the embedder.
  Future<double?> confidence(String query, {String? topicFilter}) async {
    if (!_embedder.isEnabled) return null;

    final queryVec = await _embedder.embedQuery(query);
    if (queryVec.isEmpty) return null;

    final embeddings = await _db.getAllEmbeddings(topicFilter: topicFilter);
    if (embeddings.isEmpty) return null;

    var best = 0.0;
    for (final entry in embeddings) {
      final (_, vec) = entry;
      final score = EmbeddingService.cosine(queryVec, vec);
      if (score > best) best = score;
    }
    return best;
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  /// The dense leg alone, best first.
  ///
  /// Brute-force cosine against every stored embedding. The corpus is ~200
  /// passages, so O(200 x 768) is sub-millisecond on ARM and no approximate
  /// nearest-neighbour index is needed.
  ///
  /// Public because it is the one ranking that is fully determined — same
  /// vectors, same cosine, same sort as the Python lab — and so the one that
  /// can be asserted identical in a test. The fused ranking cannot be: its
  /// lexical legs are FTS5's bm25() here and Okapi BM25 there.
  ///
  /// Returns an empty list when nothing has been embedded yet.
  Future<List<String>> denseCandidates(
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
  ///   score(d) = Σ_i  weight_i / (rank(d, list_i) + K)
  ///
  /// Empty lists are silently skipped — the RRF gracefully degrades to
  /// whichever signals are available.
  List<String> _rrfMerge({
    required List<List<String>> rankedLists,
    required List<double> weights,
    required int topK,
  }) {
    final scores = <String, double>{};

    for (var leg = 0; leg < rankedLists.length; leg++) {
      final list = rankedLists[leg];
      final weight = weights[leg];
      for (var i = 0; i < list.length; i++) {
        final id = list[i];
        scores[id] = (scores[id] ?? 0.0) + weight / (i + 1 + _rrfK);
      }
    }

    final sorted = scores.keys.toList()
      ..sort((a, b) => scores[b]!.compareTo(scores[a]!));

    return sorted.take(topK).toList();
  }
}
