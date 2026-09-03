import '../models/chat_message.dart';
import 'expansion_terms.dart';

/// How the retrieval query for a follow-up turn is built from history.
enum TurnStrategy {
  /// The turn text alone. What the app did before, and measurably the worst.
  bare,

  /// The turn text plus the previous user turns, whole.
  window,

  /// The turn text plus only the topic-bearing terms of earlier turns.
  anchored,
}

/// Builds the retrieval query for one conversational turn.
///
/// A conversation's second question rarely stands on its own. "Should I tie
/// something above it" carries no topic word at all, so retrieving on the turn
/// text alone searches eighteen guides for `tie` and `above` and finds
/// whatever happens to share those words.
///
/// Measured over 12 conversations / 32 turns (`python -m evals multiturn`):
///
///     strategy    all turns   turn 1   follow-ups   drop
///     bare            59.4%    66.7%        55.0%  -11.7%
///     window          62.5%    66.7%        60.0%   -6.7%
///     anchored        68.8%    66.7%        70.0%   +3.3%
///
/// [TurnStrategy.anchored] carries only topic-bearing terms, so a long
/// conversation cannot drown the current question in its own past. It removes
/// the follow-up penalty entirely and is the default.
///
/// All of this is pure string work — no model call before retrieval, which
/// matters because the user is waiting and the device has one small model to
/// spend time on, not two.
///
/// Mirrors `python/survive_rag/retrieval/conversation.py`.
class Conversation {
  /// How many previous user turns to draw topic terms from.
  static const int historyTurns = 2;

  /// Cap on carried terms, so history cannot outweigh the current question.
  static const int maxAnchorTerms = 8;

  /// Words that carry no topic and would only dilute the query.
  static const _stopwords = {
    'a',
    'an',
    'and',
    'are',
    'as',
    'at',
    'be',
    'but',
    'by',
    'can',
    'do',
    'does',
    'for',
    'from',
    'had',
    'has',
    'have',
    'he',
    'her',
    'him',
    'his',
    'how',
    'i',
    'if',
    'in',
    'is',
    'it',
    'its',
    'me',
    'my',
    'no',
    'not',
    'of',
    'on',
    'or',
    'our',
    'out',
    'she',
    'should',
    'so',
    'that',
    'the',
    'their',
    'them',
    'then',
    'there',
    'they',
    'this',
    'to',
    'up',
    'was',
    'we',
    'were',
    'what',
    'when',
    'where',
    'which',
    'who',
    'why',
    'will',
    'with',
    'you',
    'your',
    'am',
    'been',
    'being',
    'did',
    'get',
    'got',
    'us',
    'about',
  };

  static final _token = RegExp(r"[a-z0-9']+");

  static List<String> _tokenize(String text) =>
      _token.allMatches(text.toLowerCase()).map((m) => m.group(0)!).toList();

  /// The most recent user messages, oldest first.
  static List<String> _recentUserTurns(List<ChatMessage> history, int limit) {
    final users = history
        .where((m) => m.role == 'user')
        .map((m) => m.content)
        .toList();
    return users.length <= limit ? users : users.sublist(users.length - limit);
  }

  /// Topic-bearing terms from earlier turns, most recent first.
  ///
  /// A term earns its place by being a word the corpus actually uses or a
  /// known Hinglish bridge word; everything else is conversational filler.
  static List<String> anchorTerms(
    List<String> earlierTurns, {
    Set<String> vocabulary = const {},
  }) {
    final seen = <String>{};
    final picked = <String>[];

    for (final text in earlierTurns.reversed) {
      for (final token in _tokenize(text)) {
        if (_stopwords.contains(token) || seen.contains(token)) continue;
        if (vocabulary.contains(token) || kExpansionTerms.containsKey(token)) {
          seen.add(token);
          picked.add(token);
          if (picked.length >= maxAnchorTerms) return picked;
        }
      }
    }
    return picked;
  }

  /// The text to retrieve on for [turn], given what came before.
  ///
  /// [vocabulary] is the corpus term set, used by [TurnStrategy.anchored] to
  /// tell topic words from filler. An empty set falls back to the expansion
  /// vocabulary alone, which still covers the Hinglish bridge words.
  static String retrievalQuery(
    String turn,
    List<ChatMessage> history, {
    TurnStrategy strategy = TurnStrategy.anchored,
    Set<String> vocabulary = const {},
  }) {
    if (strategy == TurnStrategy.bare) return turn;

    final previous = _recentUserTurns(history, historyTurns);
    if (previous.isEmpty) return turn;

    if (strategy == TurnStrategy.window) {
      return [...previous, turn].join(' ');
    }

    final anchors = anchorTerms(previous, vocabulary: vocabulary);
    return anchors.isEmpty ? turn : [turn, ...anchors].join(' ');
  }
}
