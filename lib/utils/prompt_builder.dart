import '../models/chat_message.dart';
import '../models/doc_chunk.dart';

/// Builds the full prompt string in Gemma 3's expected chat format.
///
/// Gemma 3 uses turn delimiters:
///   start_of_turn + role + newline + content + end_of_turn
///
/// The system prompt is injected as a "system" turn at the start.
/// Retrieved RAG chunks are embedded in the system prompt as [CONTEXT].
class PromptBuilder {
  static const _systemBase = '''You are Survive AI — an expert survival assistant.
Your purpose is to help people in dangerous situations: conflict zones, disasters, wilderness emergencies.
Answer concisely and practically. Prioritize life safety.
Use ONLY the provided [CONTEXT] to answer. If the context is insufficient, say so clearly.
Never make up information. When in doubt, recommend seeking professional help if available.
Do not provide specific medication dosages. This information is for general survival guidance only.''';

  static const _startTurn = '<start_of_turn>';
  static const _endTurn = '<end_of_turn>\n';

  /// Build the complete prompt for a RAG-augmented chat turn.
  ///
  /// [chunks] — retrieved doc chunks; may be empty if no docs loaded yet.
  /// [history] — conversation history (oldest first).
  /// [userMessage] — the user's current message.
  static String buildChatPrompt({
    required List<DocChunk> chunks,
    required List<ChatMessage> history,
    required String userMessage,
  }) {
    final buffer = StringBuffer();

    // System turn with embedded context
    final context = _buildContext(chunks);
    final systemContent = context.isEmpty
        ? _systemBase
        : '$_systemBase\n\n[CONTEXT]\n$context\n[/CONTEXT]';

    buffer.write('$_startTurn system\n$systemContent$_endTurn');

    // Conversation history (limited to last 6 turns to stay within budget)
    final recentHistory = history.length > 6 ? history.sublist(history.length - 6) : history;
    for (final msg in recentHistory) {
      final role = msg.role == 'user' ? 'user' : 'model';
      buffer.write('$_startTurn $role\n${msg.content}$_endTurn');
    }

    // Current user message — leave model turn open for generation
    buffer.write('$_startTurn user\n$userMessage$_endTurn');
    buffer.write('$_startTurn model\n');

    return buffer.toString();
  }

  /// Build the single-call prompt for intent classification.
  /// Expected reply: exactly one word — CHAT, ASSESS, or GUIDE.
  static String buildIntentPrompt(String userMessage) {
    return '''$_startTurn system
Classify the user's intent. Reply with exactly one word:
- CHAT: general question or conversation
- ASSESS: user wants to assess their survival situation
- GUIDE: user wants step-by-step instructions for a specific task
$_endTurn$_startTurn user
$userMessage$_endTurn$_startTurn model
''';
  }

  /// Build the prompt for extracting structured situation JSON.
  static String buildSituationExtractionPrompt(String rawDescription) {
    return '''$_startTurn system
Extract survival situation details from the description. Reply ONLY with valid JSON matching this schema:
{"environment":"jungle|desert|urban|mountain|coastal|unknown","injuries":[],"resources":[],"companions":0,"primary_goal":"escape|shelter|medical|rescue_signal|other","urgency":"critical|high|medium|low"}
$_endTurn$_startTurn user
$rawDescription$_endTurn$_startTurn model
''';
  }

  /// Build the prompt for generating a prioritized action plan.
  static String buildActionPlanPrompt({
    required String situationSummary,
    required List<DocChunk> chunks,
  }) {
    final context = _buildContext(chunks);
    return '''$_startTurn system
You are a survival expert. Generate a numbered action plan based on the situation and reference material.
Each step must be: immediately actionable, specific, ordered by priority (life safety first), max 2 sentences.
Format each step as: N. [PRIORITY: CRITICAL|HIGH|MEDIUM] Title — Detail

Reference material:
$context
$_endTurn$_startTurn user
Situation: $situationSummary

Generate a survival action plan.$_endTurn$_startTurn model
''';
  }

  static String _buildContext(List<DocChunk> chunks) {
    if (chunks.isEmpty) return '';
    return chunks.map((c) {
      final source = c.headingPath.isNotEmpty
          ? '${c.topic}/${c.docId} > ${c.headingPath}'
          : '${c.topic}/${c.docId}';
      return '--- From: $source ---\n${c.body}';
    }).join('\n\n');
  }
}
