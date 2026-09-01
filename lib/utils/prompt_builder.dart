import '../models/chat_message.dart';
import '../services/llm_service.dart';
import '../models/doc_chunk.dart';

/// Builds the prompt string for on-device Gemma 2B inference.
///
/// CRITICAL: The prompt is returned as PLAIN TEXT without turn markers.
/// flutter_gemma's `addQueryChunk()` automatically wraps text in
/// `<start_of_turn>user\n...<end_of_turn>\n<start_of_turn>model\n`
/// for GemmaIt + binary models. Adding our own markers causes double-
/// wrapping, which corrupts the prompt and crashes inference.
///
/// PROMPT STRUCTURE (optimized for 2B models):
/// Small models attend most strongly to tokens near the END of the prompt.
/// Therefore we place reference material (RAG context) first, conversation
/// history next, and the instruction + question LAST — right where the model
/// starts generating. This prevents the "forgotten instructions" problem
/// where a 260-token system prompt at the top gets ignored.
///
/// Token budget is derived from [kMaxPromptTokens] so it can never drift out of
/// sync with the context window actually configured on the model.
class PromptBuilder {
  /// Max prompt tokens, derived from the model's configured context window.
  static const int _maxPromptTokens = kMaxPromptTokens;

  /// Short instruction placed RIGHT BEFORE the question (~60 tokens).
  ///
  /// On a 2B model, a long system prompt at the top of the context gets
  /// ignored by the time the model generates. Instead, we place a short,
  /// focused instruction immediately before the question where the model
  /// attends most strongly. This dramatically improves instruction-following.
  static const _instruction =
      'You are Survive AI, an offline survival expert. '
      'Answer the question below directly and helpfully. '
      'If the user message is a greeting respond by telling about you and how you can help. '
      'Give the most critical action FIRST, then supporting steps. '
      'Be specific with distances, times, and quantities. '
      'Assume there is no network and no ambulance coming: give steps the user '
      'can do themselves right now. Mention 112 only as a second line, never as '
      'the whole answer. '
      'Do not add filler phrases. '
      'Take the user\'s request very seriously — never tell them it is only a warning or not serious. '
      'The user is in India: prefer Indian emergency numbers (112), Indian names for '
      'things, and advice that works with what an Indian household actually has.';

  /// Build the complete prompt for a RAG-augmented chat turn.
  ///
  /// Returns plain text — flutter_gemma adds turn markers automatically.
  ///
  /// Prompt layout (top → bottom):
  ///   1. RAG reference material (if any) — farthest from generation point
  ///   2. Conversation history (if any)
  ///   3. Instruction — RIGHT BEFORE the question
  ///   4. Question — immediately before generation starts
  ///
  /// [chunks] — retrieved doc chunks; may be empty if no docs loaded yet.
  /// [history] — conversation history (oldest first), EXCLUDING the current message.
  /// [userMessage] — the user's current message.
  static String buildChatPrompt({
    required List<DocChunk> chunks,
    required List<ChatMessage> history,
    required String userMessage,
  }) {
    final buffer = StringBuffer();
    var usedTokens = 0;

    // Reserve space for instruction + question (always included, highest priority)
    final instructionTokens = _estimateTokens(_instruction);
    final userTokens = _estimateTokens(userMessage) + 5; // "Question: " prefix
    usedTokens += instructionTokens + userTokens;

    // 1. RAG context (placed first — reference material for the model to draw from)
    final context = _buildContext(chunks);
    if (context.isNotEmpty) {
      final contextTokens = _estimateTokens(context) + 4;
      if (usedTokens + contextTokens + 50 < _maxPromptTokens) {
        buffer.writeln('Reference information from survival guides:');
        buffer.writeln(context);
        buffer.writeln();
        usedTokens += contextTokens + 6;
      }
    }

    // 2. Conversation history (middle — provides continuity)
    final remainingBudget = _maxPromptTokens - usedTokens;
    if (history.isNotEmpty && remainingBudget > 50) {
      final historyText = _buildHistory(history, remainingBudget);
      if (historyText.isNotEmpty) {
        buffer.writeln(historyText);
        buffer.writeln();
      }
    }

    // 3. Instruction — RIGHT BEFORE the question (where 2B model attends most)
    if (context.isNotEmpty) {
      buffer.writeln(
        '$_instruction Use the reference information above to answer.',
      );
    } else {
      buffer.writeln(_instruction);
    }
    buffer.writeln();

    // 4. Question — last thing before the model generates
    buffer.write('Question: $userMessage');

    return buffer.toString();
  }

  /// Build conversation history text, fitting within [maxTokens].
  ///
  /// Takes the most recent 4 turns. Uses Q:/A: format instead of
  /// User:/Assistant: to avoid role confusion when the entire prompt
  /// is inside a single `<start_of_turn>user` block.
  static String _buildHistory(List<ChatMessage> history, int maxTokens) {
    final recent = history.length > 4
        ? history.sublist(history.length - 4)
        : history;

    final lines = <String>[];
    var tokens = 5; // header

    for (final msg in recent) {
      final label = msg.role == 'user' ? 'Q' : 'A';
      var content = msg.content;
      if (content.length > 400) {
        content = '${content.substring(0, 397)}...';
      }
      final line = '$label: $content';
      final lineTokens = _estimateTokens(line);

      if (tokens + lineTokens > maxTokens) break;
      lines.add(line);
      tokens += lineTokens;
    }

    if (lines.isEmpty) return '';
    return 'Previous exchange:\n${lines.join('\n')}';
  }

  /// Build the reference material block from retrieved chunks.
  ///
  /// Each chunk is capped at [_maxChunkChars] to leave room for the
  /// instruction + question near the end of the prompt. Four chunks at the
  /// old 1000-char cap alone exceeded the real context window.
  static const int _maxChunkChars = 700;

  static String _buildContext(List<DocChunk> chunks) {
    if (chunks.isEmpty) return '';
    return chunks
        .map((c) {
          final source = c.headingPath.isNotEmpty
              ? '${c.topic} > ${c.headingPath}'
              : c.topic;
          var body = c.body;
          if (body.length > _maxChunkChars) {
            body = '${body.substring(0, _maxChunkChars - 3)}...';
          }
          return '[$source]\n$body';
        })
        .join('\n\n');
  }

  /// Rough token estimate: words × 1.3 (same heuristic as ChunkerService).
  static int _estimateTokens(String text) =>
      (text.split(RegExp(r'\s+')).length * 1.3).ceil();
}
