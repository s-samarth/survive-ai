import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/chat_message.dart';
import '../providers/providers.dart';
import '../services/agent_orchestrator.dart';
import '../utils/prompt_builder.dart';
import '../widgets/message_bubble.dart';
import 'situation_screen.dart';
import 'step_guide_screen.dart';

/// Main chat interface — RAG-augmented conversation with the on-device LLM.
///
/// [topicFilter] — optional topic to scope RAG retrieval (e.g. from doc reader).
/// [enableIntentClassification] — when true (default for main chat), classifies
/// user intent and may redirect to SituationScreen or StepGuideScreen.
class ChatScreen extends ConsumerStatefulWidget {
  final String? topicFilter;
  final bool enableIntentClassification;

  const ChatScreen({
    super.key,
    this.topicFilter,
    this.enableIntentClassification = true,
  });

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  final List<ChatMessage> _history = [];
  bool _isGenerating = false;
  String _streamingBuffer = '';

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _sendMessage() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _isGenerating) return;

    _controller.clear();
    setState(() {
      _history.add(ChatMessage(role: 'user', content: text, timestamp: DateTime.now()));
      _isGenerating = true;
      _streamingBuffer = '';
    });
    _scrollToBottom();

    try {
      final llm = ref.read(llmServiceProvider);
      final rag = ref.read(ragServiceProvider);

      // Intent classification (only in main chat, not scoped chats)
      if (widget.enableIntentClassification && widget.topicFilter == null) {
        final intentPrompt = PromptBuilder.buildIntentPrompt(text);
        final intentBuffer = StringBuffer();
        await for (final token in llm.chat(prompt: intentPrompt)) {
          intentBuffer.write(token);
        }
        final intent = parseIntent(intentBuffer.toString());

        if (intent == AgentIntent.assess && mounted) {
          setState(() {
            _isGenerating = false;
            _streamingBuffer = '';
          });
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const SituationScreen()),
          );
          return;
        }

        if (intent == AgentIntent.guide && mounted) {
          // Generate step-by-step guide
          setState(() => _streamingBuffer = 'Generating step-by-step guide…');
          _scrollToBottom();

          final chunks = await rag.retrieve(text, topicFilter: widget.topicFilter);
          final prompt = PromptBuilder.buildChatPrompt(
            chunks: chunks,
            history: [],
            userMessage: 'Give me step-by-step instructions for: $text. '
                'Number each step. Keep each step to 1-2 sentences.',
          );

          final guideBuffer = StringBuffer();
          await for (final token in llm.chat(prompt: prompt)) {
            guideBuffer.write(token);
          }

          final steps = _parseGuideSteps(guideBuffer.toString());
          if (steps.isNotEmpty && mounted) {
            setState(() {
              _isGenerating = false;
              _streamingBuffer = '';
            });
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => StepGuideScreen(
                  title: text,
                  steps: steps,
                  topic: widget.topicFilter,
                ),
              ),
            );
            return;
          }
          // If parsing failed, fall through to normal chat
        }
      }

      // Normal CHAT flow: RAG retrieval + streaming response
      final chunks = await rag.retrieve(text, topicFilter: widget.topicFilter);
      final prompt = PromptBuilder.buildChatPrompt(
        chunks: chunks,
        history: _history.where((m) => m.role != 'assistant' || _history.last != m).toList(),
        userMessage: text,
      );

      final buffer = StringBuffer();
      await for (final token in llm.chat(prompt: prompt)) {
        buffer.write(token);
        setState(() => _streamingBuffer = buffer.toString());
        _scrollToBottom();
      }

      setState(() {
        _history.add(ChatMessage(
          role: 'assistant',
          content: buffer.toString(),
          timestamp: DateTime.now(),
        ));
        _streamingBuffer = '';
        _isGenerating = false;
      });
    } catch (e) {
      setState(() {
        _history.add(ChatMessage(
          role: 'assistant',
          content: 'Error: ${e.toString()}',
          timestamp: DateTime.now(),
        ));
        _streamingBuffer = '';
        _isGenerating = false;
      });
    }
    _scrollToBottom();
  }

  List<String> _parseGuideSteps(String response) {
    final lines = response.split('\n');
    final steps = <String>[];
    final buffer = StringBuffer();

    for (final line in lines) {
      // Check if this line starts a new numbered step
      if (RegExp(r'^\d+[\.\)]\s').hasMatch(line.trim()) && buffer.isNotEmpty) {
        steps.add(buffer.toString().trim());
        buffer.clear();
      }
      if (line.trim().isNotEmpty) {
        if (buffer.isNotEmpty) buffer.write('\n');
        buffer.write(line.replaceFirst(RegExp(r'^\d+[\.\)]\s*'), '').trim());
      }
    }
    if (buffer.isNotEmpty) {
      steps.add(buffer.toString().trim());
    }
    return steps.where((s) => s.isNotEmpty).toList();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final llmReady = ref.watch(llmReadyProvider);

    return Column(
      children: [
        if (!llmReady)
          Container(
            color: Colors.orange[100],
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: const Row(
              children: [
                Icon(Icons.download, size: 16),
                SizedBox(width: 8),
                Text('AI model is loading…', style: TextStyle(fontSize: 13)),
              ],
            ),
          ),
        Expanded(
          child: ListView.builder(
            controller: _scrollController,
            padding: const EdgeInsets.all(16),
            itemCount: _history.length + (_isGenerating ? 1 : 0),
            itemBuilder: (context, index) {
              if (index == _history.length) {
                return MessageBubble(
                  message: ChatMessage(
                    role: 'assistant',
                    content: _streamingBuffer,
                    timestamp: DateTime.now(),
                  ),
                  isStreaming: true,
                );
              }
              return MessageBubble(message: _history[index]);
            },
          ),
        ),
        _InputBar(
          controller: _controller,
          enabled: llmReady && !_isGenerating,
          onSend: _sendMessage,
        ),
      ],
    );
  }
}

class _InputBar extends StatelessWidget {
  final TextEditingController controller;
  final bool enabled;
  final VoidCallback onSend;

  const _InputBar({
    required this.controller,
    required this.enabled,
    required this.onSend,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      child: SafeArea(
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                enabled: enabled,
                maxLines: null,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => onSend(),
                decoration: InputDecoration(
                  hintText: enabled ? 'Ask a survival question…' : 'Loading AI…',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(24)),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              onPressed: enabled ? onSend : null,
              icon: const Icon(Icons.send),
              tooltip: 'Send',
            ),
          ],
        ),
      ),
    );
  }
}
