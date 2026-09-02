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

  /// Tokens held back for conversation history whenever there is any, so a
  /// long reference block can never crowd out the thread of the conversation.
  static const int _historyReserveTokens = 220;

  /// Turns considered for history, newest first.
  static const int maxHistoryTurns = 4;

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
    //
    // Fit as many chunks as the budget allows rather than accepting or
    // rejecting the whole block. The previous all-or-nothing form failed
    // silently and catastrophically: when the block did not fit, the model
    // received NO reference material at all and answered from its own
    // pretraining — the exact failure retrieval exists to prevent, and
    // invisible to anything that does not inspect the prompt.
    final selected = selectContextChunks(
      chunks: chunks,
      history: history,
      userMessage: userMessage,
    );
    if (selected.isNotEmpty) {
      final context = selected.map(_renderChunk).join('\n\n');
      buffer.writeln('Reference information from survival guides:');
      buffer.writeln(context);
      buffer.writeln();
      usedTokens += _estimateTokens(context) + 6;
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
    if (selected.isNotEmpty) {
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

  /// Longest a user's own question is allowed to be in history.
  ///
  /// Questions are short and load-bearing: "should I tie something above it"
  /// is what the next retrieval and the next answer both hang on.
  static const int _maxUserChars = 400;

  /// Longest a previous answer is allowed to be.
  ///
  /// Answers are long — a median of ~89 tokens — and recoverable: the model
  /// can restate advice, but it cannot recover a question it never saw. So
  /// they are cut harder than questions when the budget is tight.
  static const int _maxAssistantChars = 220;

  /// Build conversation history text, fitting within [maxTokens].
  ///
  /// Walks from the MOST RECENT backwards. The previous version filled
  /// oldest-first and stopped at the budget, which kept the oldest turns and
  /// dropped the newest — exactly backwards for a follow-up question, where
  /// the last exchange is the one the current turn depends on.
  ///
  /// Uses Q:/A: instead of User:/Assistant: to avoid role confusion, since the
  /// whole prompt sits inside a single `<start_of_turn>user` block.
  static String _buildHistory(List<ChatMessage> history, int maxTokens) {
    final recent = history.length > maxHistoryTurns
        ? history.sublist(history.length - maxHistoryTurns)
        : history;

    final lines = <String>[];
    var tokens = 5; // header

    for (final msg in recent.reversed) {
      final isUser = msg.role == 'user';
      final cap = isUser ? _maxUserChars : _maxAssistantChars;
      var content = msg.content;
      if (content.length > cap) {
        content = '${content.substring(0, cap - 3)}...';
      }
      final line = '${isUser ? 'Q' : 'A'}: $content';
      final lineTokens = _estimateTokens(line);

      // Always keep the most recent turn: a follow-up without it is
      // unanswerable, and an oversized turn beats an absent one.
      if (lines.isNotEmpty && tokens + lineTokens > maxTokens) break;
      lines.add(line);
      tokens += lineTokens;
    }

    if (lines.isEmpty) return '';
    return 'Previous exchange:\n${lines.reversed.join('\n')}';
  }

  /// Per-chunk character cap.
  ///
  /// 700 was tuned when a chunk was one ~90-token paragraph. Retrieval now
  /// scores 320-token passages, and at 700 characters that truncated 91% of
  /// them — discarding ~600 characters each while 39% of the token budget sat
  /// unused. At 1400, truncation drops to 30% and five chunks fill 91% of the
  /// budget.
  static const int _maxChunkChars = 1400;

  /// The chunks that will actually fit in the prompt, best first.
  ///
  /// Exposed because citations must reflect what the model was actually shown:
  /// a citation pointing at a chunk that never reached the context is a lie
  /// about where the answer came from.
  static List<DocChunk> selectContextChunks({
    required List<DocChunk> chunks,
    required List<ChatMessage> history,
    required String userMessage,
  }) {
    if (chunks.isEmpty) return const [];

    final overhead =
        _estimateTokens(_instruction) + _estimateTokens(userMessage) + 5;
    final reserve = history.isEmpty ? 0 : _historyReserveTokens;
    final budget = _maxPromptTokens - overhead - reserve - 10;
    if (budget <= 0) return const [];

    final kept = <DocChunk>[];
    var used = 0;
    for (final chunk in chunks) {
      final cost = _estimateTokens(_renderChunk(chunk)) + 2;
      // The best chunk is always kept: an oversized one still beats nothing.
      if (kept.isNotEmpty && used + cost > budget) break;
      kept.add(chunk);
      used += cost;
    }
    return kept;
  }

  /// Render one chunk as `[source]\nbody`, truncated to [_maxChunkChars].
  static String _renderChunk(DocChunk c) {
    final source = c.headingPath.isNotEmpty
        ? '${c.topic} > ${c.headingPath}'
        : c.topic;
    var body = c.body;
    if (body.length > _maxChunkChars) {
      body = '${body.substring(0, _maxChunkChars - 3)}...';
    }
    return '[$source]\n$body';
  }

  /// Rough token estimate: words × 1.3 (same heuristic as ChunkerService).
  static int _estimateTokens(String text) =>
      (text.split(RegExp(r'\s+')).length * 1.3).ceil();
}
