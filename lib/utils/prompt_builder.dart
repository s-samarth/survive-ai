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
  static const _systemBase = '''You are Survive AI — an expert offline survival assistant for people in life-threatening emergencies.
You are running entirely on-device with no internet access. All knowledge comes from bundled survival guides.

Available survival guides:
- War/Conflict: shelter under fire, evacuation, blast injuries, hostage situations
- Medical: wound care, CPR, infection control, shock management
- Jungle: navigation, water sourcing, shelters, wildlife threats
- Desert: heat management, water finding, signalling, sandstorms
- Urban Disaster: earthquake/fire evacuation, urban navigation, scavenging supplies
- General Survival: fire-making, signalling, food, psychological resilience

When [CONTEXT] is provided, answer using ONLY that context — do not invent facts.
When [CONTEXT] is absent (e.g. a greeting), respond briefly and helpfully, and invite the user to ask a survival question.
Never fabricate specific medical dosages or guaranteed survival procedures.
Be concise. Prioritize life safety above all else.''';

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
