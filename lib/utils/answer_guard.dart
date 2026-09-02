import '../models/doc_chunk.dart';

/// What to do with a generated answer before showing it.
enum GuardAction {
  /// The answer asserts something its own reference material forbids.
  block,

  /// The answer is right but dropped a warning the material carries.
  augment,

  /// Safe to show unchanged.
  pass,
}

/// The outcome of checking one answer against the chunks it was built from.
class GuardResult {
  const GuardResult(this.action, {this.violations = const [], this.omissions = const []});

  final GuardAction action;

  /// Forbidden actions the answer asserted. Non-empty means [GuardAction.block].
  final List<String> violations;

  /// Forbidden actions the answer never mentioned, to append verbatim.
  final List<String> omissions;
}

/// Catches an answer that contradicts the guides it was given.
///
/// The generation eval measured Gemma 2B preserving prohibitions perfectly on
/// single-turn questions and failing three times in thirty-two conversational
/// turns — always on a follow-up, always by dropping a "DO NOT" while copying
/// the rest of a chunk. A larger model would help; a larger model does not fit
/// in 4 GB alongside the embedder.
///
/// So the check runs after generation instead. It is pure string work,
/// microseconds, no model, and it knows something the model does not reliably
/// use: exactly which prohibitions were in the context it was handed.
///
/// Two failure modes, two responses. An answer that *asserts* something its
/// own material forbids is wrong and must not be shown. One that merely
/// *omits* a warning is incomplete, and the warning is appended verbatim —
/// the guide text is never wrong.
///
/// Mirrors `python/survive_rag/safety.py` and `polarity.py`, which the eval
/// harness imports, so the thing measured and the thing shipped cannot drift.
class AnswerGuard {
  /// Cues that negate what FOLLOWS them; position matters.
  static const _prefixCues = [
    'do not', "don't", 'dont', 'never', 'no ', 'not ', 'must not',
    'must never', 'should not', "shouldn't", 'cannot', "can't", 'avoid',
    'refrain', 'stop', 'without', 'instead of', 'rather than',
  ];

  /// Predicates ABOUT a phrase, which may follow it: "applying ice is harmful".
  /// Deliberately narrow and mostly multi-word — a bare "harmful" would
  /// misread "apply pressure to stop the harmful bleeding".
  static const _clauseCues = [
    'myth', 'mistake', 'is harmful', 'are harmful', 'is dangerous',
    'are dangerous', 'does not work', "doesn't work", 'do not work',
    'ineffective', 'is unsafe', 'causes harm', 'causes gangrene', 'is wrong',
    'makes it worse', 'worsens',
  ];

  static const _dangling = {
    'the', 'a', 'an', 'to', 'of', 'it', 'you', 'your', 'are', 'is', 'and',
    'or', 'for', 'in', 'on',
  };

  static final _clauseSplit = RegExp(r'[.!?\n;:]|\s+--\s+|\s+—\s+|,\s+(?:but|and|or|because)\s+');

  /// Anchored to the START of a clause, so a claim about efficacy —
  /// "tourniquets do not stop venom spread" — is not read as an instruction.
  static final _prohibition = RegExp(
    r"^(?:do not|don't|never)\s+([a-z][a-z' ]{4,50})",
    caseSensitive: false,
  );

  static final _markup = RegExp(r'[*_`#\[\]]');

  static const _maxActionWords = 5;

  /// Split [text] into polarity-bearing clauses, lowercased.
  static List<String> clauses(String text) => text
      .split(_clauseSplit)
      .map((c) => c.trim().toLowerCase())
      .where((c) => c.isNotEmpty)
      .toList();

  static bool _isNegated(String clause, int position) {
    final head = clause.substring(0, position);
    return _prefixCues.any(head.contains) || _clauseCues.any(clause.contains);
  }

  /// True when [text] asserts [phrase] rather than warning against it.
  ///
  /// A correct answer must *say* the dangerous phrase in order to forbid it,
  /// so asking whether the phrase occurs is useless. This asks what the
  /// sentence does with it.
  static bool affirms(String text, String phrase) {
    final needle = phrase.toLowerCase();
    for (final clause in clauses(text)) {
      final start = clause.indexOf(needle);
      if (start >= 0 && !_isNegated(clause, start)) return true;
    }
    return false;
  }

  /// True when [text] mentions [phrase] and warns against it.
  static bool negates(String text, String phrase) {
    final needle = phrase.toLowerCase();
    for (final clause in clauses(text)) {
      final start = clause.indexOf(needle);
      if (start >= 0 && _isNegated(clause, start)) return true;
    }
    return false;
  }

  /// Actions the reference material tells the reader not to do.
  static List<String> forbiddenActions(String context) {
    final found = <String>[];
    for (final clause in clauses(context.replaceAll(_markup, ''))) {
      final match = _prohibition.firstMatch(clause.replaceAll(RegExp(r'^[-•*\s]+'), ''));
      if (match == null) continue;

      final words = match.group(1)!.trim().split(RegExp(r'\s+'));
      final kept = words.take(_maxActionWords).toList();
      while (kept.isNotEmpty && _dangling.contains(kept.last)) {
        kept.removeLast();
      }
      final action = kept.join(' ').toLowerCase().trim();
      if (action.length > 4 && !found.contains(action)) found.add(action);
    }
    return found;
  }

  /// Decide whether [answer] is safe to show, given the [chunks] it was built
  /// from.
  ///
  /// [maxOmissions] caps appended warnings so a chunk dense with prohibitions
  /// does not bury the answer itself.
  static GuardResult check(
    String answer,
    List<DocChunk> chunks, {
    int maxOmissions = 2,
  }) {
    final context = chunks.map((c) => c.body).join('\n\n');
    final forbidden = forbiddenActions(context);

    final violations = forbidden.where((a) => affirms(answer, a)).toList();
    if (violations.isNotEmpty) {
      return GuardResult(GuardAction.block, violations: violations);
    }

    final low = answer.toLowerCase();
    final omissions = forbidden
        .where((a) => !low.contains(a) && !negates(answer, a))
        .take(maxOmissions)
        .toList();

    return omissions.isEmpty
        ? const GuardResult(GuardAction.pass)
        : GuardResult(GuardAction.augment, omissions: omissions);
  }
}
