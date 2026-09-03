import '../models/chat_message.dart';

/// Rendering conversation history into the prompt, inside a token budget.
///
/// Context management is where a small model is won or lost: 1452 tokens have
/// to hold the reference material, the thread of the conversation, the
/// instruction and the question, and whatever is cut is simply gone.
class PromptHistory {
  /// Turns considered, newest first.
  static const int maxTurns = 4;

  /// Longest a user's own question is allowed to be in history.
  ///
  /// Questions are short and load-bearing: "should I tie something above it"
  /// is what the next retrieval and the next answer both hang on.
  static const int maxUserChars = 400;

  /// Longest a previous answer is allowed to be.
  ///
  /// Answers are long — a median of ~89 tokens — and recoverable: the model
  /// can restate advice, but it cannot recover a question it never saw. So
  /// they are cut harder than questions when the budget is tight.
  static const int maxAssistantChars = 220;

  /// Build conversation history text, fitting within [maxTokens].
  ///
  /// Walks from the MOST RECENT backwards. The previous version filled
  /// oldest-first and stopped at the budget, which kept the oldest turns and
  /// dropped the newest — exactly backwards for a follow-up question, where
  /// the last exchange is the one the current turn depends on.
  ///
  /// Uses Q:/A: instead of User:/Assistant: to avoid role confusion, since the
  /// whole prompt sits inside a single `<start_of_turn>user` block.
  static String render(List<ChatMessage> history, int maxTokens) {
    final recent = history.length > maxTurns
        ? history.sublist(history.length - maxTurns)
        : history;

    final lines = <String>[];
    var tokens = 5; // header

    for (final msg in recent.reversed) {
      final isUser = msg.role == 'user';
      final cap = isUser ? maxUserChars : maxAssistantChars;
      var content = msg.content;
      if (content.length > cap) {
        content = '${content.substring(0, cap - 3)}...';
      }
      final line = '${isUser ? 'Q' : 'A'}: $content';
      final lineTokens = estimateTokens(line);

      // Always keep the most recent turn: a follow-up without it is
      // unanswerable, and an oversized turn beats an absent one.
      if (lines.isNotEmpty && tokens + lineTokens > maxTokens) break;
      lines.add(line);
      tokens += lineTokens;
    }

    if (lines.isEmpty) return '';
    return 'Previous exchange:\n${lines.reversed.join('\n')}';
  }

  /// Rough token estimate: words x 1.3, the same heuristic used throughout.
  static int estimateTokens(String text) =>
      (text.split(RegExp(r'\s+')).length * 1.3).ceil();
}
