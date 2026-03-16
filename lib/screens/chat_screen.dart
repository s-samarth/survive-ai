import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/chat_message.dart';
import '../providers/providers.dart';
import '../utils/prompt_builder.dart';
import '../widgets/message_bubble.dart';

/// Main chat interface — RAG-augmented conversation with the on-device LLM.
///
/// [topicFilter] — optional topic to scope RAG retrieval (e.g. from guide reader).
class ChatScreen extends ConsumerStatefulWidget {
  final String? topicFilter;

  const ChatScreen({super.key, this.topicFilter});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  final List<ChatMessage> _history = [];
  bool _isGenerating = false;
  String _streamingBuffer = '';

  // Timer used to batch token-streaming setState calls.
  // Without batching, every token triggers a setState + String allocation,
  // causing ~512 GC cycles per response and measurable memory pressure.
  Timer? _streamFlushTimer;

  @override
  void dispose() {
    _streamFlushTimer?.cancel();
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
      final rag = ref.read(ragServiceProvider);
      final llm = ref.read(llmServiceProvider);

      final chunks = await rag.retrieve(text, topicFilter: widget.topicFilter);

      // Pass only the history BEFORE the current user message.
      // Previously, the filter bug passed the current user message in BOTH
      // `history` and `userMessage`, duplicating it in the prompt and wasting
      // ~50-200 context tokens per turn.
      final pastHistory = _history.sublist(0, _history.length - 1);

      final prompt = PromptBuilder.buildChatPrompt(
        chunks: chunks,
        history: pastHistory,
        userMessage: text,
      );

      final buffer = StringBuffer();
      await for (final token in llm.chat(prompt: prompt)) {
        buffer.write(token);
        // Batch UI updates to ~20 fps instead of per-token.
        // Reduces setState from ~512 calls/response to ~25, cutting GC
        // pressure by ~20× during inference.
        _streamFlushTimer ??= Timer(const Duration(milliseconds: 50), () {
          _streamFlushTimer = null;
          if (mounted) {
            setState(() => _streamingBuffer = buffer.toString());
            _scrollToBottom();
          }
        });
      }

      // Final flush after stream ends
      _streamFlushTimer?.cancel();
      _streamFlushTimer = null;

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
      _streamFlushTimer?.cancel();
      _streamFlushTimer = null;
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
    final llmError = ref.watch(llmErrorProvider);

    return Column(
      children: [
        if (!llmReady && llmError == null)
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
        if (!llmReady && llmError != null)
          Container(
            color: Colors.red[100],
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                const Icon(Icons.error_outline, size: 16, color: Colors.red),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    llmError,
                    style: const TextStyle(fontSize: 12, color: Colors.red),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
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
