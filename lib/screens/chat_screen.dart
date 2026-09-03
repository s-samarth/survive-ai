import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/chat_message.dart';
import '../models/doc_chunk.dart';
import '../providers/providers.dart';
import '../services/chat_turn_service.dart';
import '../widgets/chat_empty_state.dart';
import '../widgets/chat_input_bar.dart';
import '../widgets/message_bubble.dart';
import '../widgets/retrieval_status.dart';

/// Main chat interface.
///
/// Holds no pipeline logic: it dispatches to [ChatTurnService] and renders the
/// events that come back. Routing, retrieval, prompting, generation and the
/// safety guard all live in the service, where each has a measurable failure
/// mode and none is easier to test through a `setState`.
///
/// [topicFilter] scopes retrieval, e.g. when opened from a guide.
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
  List<DocChunk> _sources = const [];

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

  Future<void> _send(String text) async {
    if (text.isEmpty || _isGenerating) return;

    _controller.clear();
    setState(() {
      _history.add(
        ChatMessage(role: 'user', content: text, timestamp: DateTime.now()),
      );
      _isGenerating = true;
      _streamingBuffer = '';
      _sources = const [];
    });
    _scrollToBottom();

    // History BEFORE the current message: passing it in both `history` and
    // `userMessage` would duplicate the question and waste context tokens.
    final past = _history.sublist(0, _history.length - 1);

    try {
      final turns = ref.read(chatTurnServiceProvider);
      await for (final event in turns.send(
        text: text,
        history: past,
        topicFilter: widget.topicFilter,
      )) {
        switch (event) {
          case TurnSources(:final chunks):
            if (mounted) setState(() => _sources = chunks);
          case TurnToken(:final text):
            // Batch to ~20 fps: per-token setState means ~512 rebuilds an
            // answer, and the GC pressure is measurable during inference.
            _streamFlushTimer ??= Timer(const Duration(milliseconds: 50), () {
              _streamFlushTimer = null;
              if (mounted) {
                setState(() => _streamingBuffer = text);
                _scrollToBottom();
              }
            });
          case TurnDone(:final answer):
            _finish(answer);
          case TurnRouted():
            break;
        }
      }
    } catch (e) {
      // Never a bare stack trace: someone reading this may be in an emergency.
      _finish(
        'Something went wrong: $e\n\nIn a life-threatening emergency '
        'call 112. You can also open the guides from the home screen.',
      );
    }
    _scrollToBottom();
  }

  /// Commit a finished answer and stop the streaming UI.
  void _finish(String answer) {
    _streamFlushTimer?.cancel();
    _streamFlushTimer = null;
    if (!mounted) return;
    setState(() {
      _history.add(
        ChatMessage(
          role: 'assistant',
          content: answer,
          timestamp: DateTime.now(),
        ),
      );
      _streamingBuffer = '';
      _isGenerating = false;
    });
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
          child: _history.isEmpty && !_isGenerating
              ? ChatEmptyState(onPickTopic: _send)
              : ListView.builder(
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
        // Six seconds pass before the first token on this hardware. Naming the
        // guide being read turns that into evidence the answer is grounded.
        if (_isGenerating && _streamingBuffer.isEmpty)
          RetrievalStatus(chunks: _sources),
        ChatInputBar(
          controller: _controller,
          enabled: llmReady && !_isGenerating,
          onSend: () => _send(_controller.text.trim()),
        ),
      ],
    );
  }
}
