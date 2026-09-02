import 'expansion_terms.dart';

/// What kind of question this is, decided before a model runs.
enum QueryIntent {
  /// The user is asking what the app is or what it can do.
  capability,

  /// The corpus can help. Retrieve and generate.
  answer,

  /// The corpus cannot help. Say so, and say what it can do.
  decline,
}

/// A routing decision, with the evidence it rested on.
class QueryRoute {
  const QueryRoute(this.intent, this.confidence, this.reason);

  final QueryIntent intent;
  final double confidence;
  final String reason;

  /// True only when a generation pass is worth spending.
  bool get shouldRetrieve => intent == QueryIntent.answer;
}

/// Decides what kind of question this is, before spending a model on it.
///
/// Three outcomes, and only one of them costs a generation pass. A capability
/// question is answered from fixed text, instantly — it is usually someone's
/// first message, so it is also the app's first impression. An out-of-scope
/// question is declined rather than improvised on. Everything else is
/// retrieved and generated.
///
/// The decline decision rests on retrieval confidence, not a keyword list,
/// because a keyword list cannot anticipate what people will ask. Measured
/// over 382 golden-set cases:
///
///     group                cosine range     bridge words
///     in-corpus English    0.304 - 0.70     no
///     in-corpus Hinglish   0.247 - 0.40     yes, 23 of 28
///     capability           0.191 - 0.358    no
///     out-of-corpus        0.085 - 0.224    no
///
/// Two consequences. Capability questions straddle the whole range, so they
/// are matched by pattern and vetoed only by a *high* confidence — "what can
/// you do about a snake bite" stays an emergency. And romanised Hindi cannot
/// be trusted to the cosine at all, since embedding models are trained on
/// Devanagari; those queries carry bridge words instead, which is direct
/// evidence of domain that the embedding cannot provide.
///
/// Mirrors `python/survive_rag/routing.py`, which `evals route --calibrate`
/// tunes.
class QueryRouter {
  /// Highest threshold with ZERO false declines over 382 cases.
  ///
  /// 0.28 scores better overall but turns away one real query, and turning
  /// away someone in an emergency is the worst thing this app can do short of
  /// giving dangerous advice.
  static const double answerThreshold = 0.25;

  /// Above this, a capability-shaped query is treated as a real question.
  static const double capabilityVeto = 0.45;

  static final _capabilityPatterns = [
    RegExp(r'^(hi|hello|hey|yo|namaste|namaskar|salaam|hola)\b[\s!.?]*$', caseSensitive: false),
    RegExp(r'^help[\s!.?]*$', caseSensitive: false),
    RegExp(r'^(who|what) (are|r) (you|u)\b', caseSensitive: false),
    RegExp(r'^(tum|aap|tu) kaun (ho|hai|hain)\b', caseSensitive: false),
    RegExp(r"^what('?s| is)? this( app| bot| thing)?[\s!.?]*$", caseSensitive: false),
    RegExp(r'\bwhat can (you|u|this app|this) do\b', caseSensitive: false),
    RegExp(r'\bhow can (you|u|this app|this) help\b', caseSensitive: false),
    RegExp(r'\bwhat do you do\b', caseSensitive: false),
    RegExp(r'\bwhat (topics|things|questions).{0,20}(cover|ask|help|answer)\b', caseSensitive: false),
    RegExp(r'\b(aap|tum|tu) kya kar sakte? (ho|hai|hain)\b', caseSensitive: false),
    RegExp(r'^kya kar sakte? (ho|hai|hain)\b', caseSensitive: false),
    RegExp(r'\byeh kya hai\b', caseSensitive: false),
    RegExp(r'\bhow (do|does) (you|this) work\b', caseSensitive: false),
  ];

  static final _token = RegExp(r"[a-z0-9']+");

  /// True when the query is about the app rather than about an emergency.
  static bool looksLikeCapabilityQuestion(String query) {
    final text = query.trim();
    if (text.isEmpty) return true;
    return _capabilityPatterns.any((p) => p.hasMatch(text));
  }

  /// True when the query leans on romanised-Hindi vocabulary.
  ///
  /// Read from the explicit transliteration list rather than inferred. An
  /// earlier version inferred it as "an expansion key the corpus never uses",
  /// which was silently wrong for any Hinglish word a guide happens to use
  /// once — `aag`, fire, being the dangerous example.
  static bool hasBridgeTerms(String query) => _token
      .allMatches(query.toLowerCase())
      .any((m) => kTransliteratedTerms.contains(m.group(0)));

  /// Decide how to handle [query].
  ///
  /// [confidence] is the top embedding cosine, or null when this build has no
  /// embedder. Null means *unknown*, which is not the same as zero: a zero was
  /// measured and justifies declining, whereas an unknown must not, because
  /// refusing on absent evidence would turn away emergencies.
  static QueryRoute route(String query, {double? confidence}) {
    final known = confidence ?? 0.0;

    if (looksLikeCapabilityQuestion(query) && known < capabilityVeto) {
      return QueryRoute(QueryIntent.capability, known, 'asks what the app does');
    }
    if (confidence == null) {
      return QueryRoute(QueryIntent.answer, known, 'no confidence signal available');
    }
    if (confidence >= answerThreshold) {
      return QueryRoute(QueryIntent.answer, confidence, 'retrieval confident');
    }
    if (hasBridgeTerms(query)) {
      return QueryRoute(
        QueryIntent.answer,
        confidence,
        'romanised Hindi bridge vocabulary',
      );
    }
    return QueryRoute(
      QueryIntent.decline,
      confidence,
      'confidence ${confidence.toStringAsFixed(2)} below threshold',
    );
  }
}
