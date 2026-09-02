import 'expansion_terms.dart';

/// Expands queries with domain-specific survival synonyms and related terms.
///
/// This provides a "semantic-like" retrieval signal by bridging vocabulary
/// gaps between user queries and survival doc terminology. The expanded
/// query is used as a second BM25 search leg in RRF, giving the retrieval
/// pipeline two independent signals to merge.
///
/// Example: "khoon nikal raha hai" → "khoon nikal raha hai blood bleeding
/// wound hemorrhage pressure"
///
/// Why not a neural embedding model? Alongside the Gemma weights, any extra
/// ML runtime costs memory the app does not have on a 4-6 GB device.
/// Expansion is pure Dart, zero memory overhead, and it closes the two gaps
/// that actually break retrieval here: user language vs medical terminology,
/// and romanised Hindi vs English.
///
/// The vocabulary itself lives in [kExpansionTerms].
class QueryExpander {
  /// Cap on how many expansion terms are appended, to avoid diluting the
  /// original query's signal in the second BM25 leg.
  static const int _maxExpansions = 10;

  /// Expand a query with related survival terms.
  ///
  /// Returns the original query with relevant expansion terms appended, or the
  /// query unchanged when nothing matched.
  static String expand(String query) {
    final words = query.toLowerCase().split(RegExp(r'[^a-z0-9]+'))
      ..removeWhere((w) => w.isEmpty);
    final expansions = <String>{};

    for (final word in words) {
      final direct = kExpansionTerms[word];
      if (direct != null) expansions.addAll(direct);

      for (final stem in _stemCandidates(word)) {
        final stemmed = kExpansionTerms[stem];
        if (stemmed != null) expansions.addAll(stemmed);
      }
    }

    expansions.removeAll(words);
    if (expansions.isEmpty) return query;

    return '$query ${expansions.take(_maxExpansions).join(' ')}';
  }

  /// Candidate stems for [word], excluding [word] itself.
  ///
  /// Deliberately shallow — full Porter stemming over-stems survival terms
  /// ("compress" -> "compr") and breaks the lookup. Both the bare stem and the
  /// stem plus a restored 'e' are tried, because English drops a silent 'e'
  /// before a suffix: "collapsing" -> "collaps" misses, "collapse" hits.
  static Iterable<String> _stemCandidates(String word) sync* {
    String? base;
    if (word.endsWith('ing') && word.length > 5) {
      base = word.substring(0, word.length - 3);
    } else if (word.endsWith('ed') && word.length > 4) {
      base = word.substring(0, word.length - 2);
    } else if (word.endsWith('ly') && word.length > 4) {
      base = word.substring(0, word.length - 2);
    } else if (word.endsWith('es') && word.length > 4) {
      base = word.substring(0, word.length - 2);
    } else if (word.endsWith('s') && !word.endsWith('ss') && word.length > 3) {
      base = word.substring(0, word.length - 1);
    }
    if (base == null || base == word) return;
    yield base;
    if (!base.endsWith('e')) yield '${base}e';
  }
}
