import 'package:flutter/material.dart';
import '../models/chat_message.dart';

/// A single chat message bubble.
///
/// User messages appear right-aligned in a filled bubble.
/// Assistant messages appear left-aligned in a surface-colored bubble.
/// [isStreaming] adds a blinking cursor while tokens are still arriving.
class MessageBubble extends StatelessWidget {
  final ChatMessage message;
  final bool isStreaming;

  const MessageBubble({
    super.key,
    required this.message,
    this.isStreaming = false,
  });

  bool get _isUser => message.role == 'user';

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    final bgColor = _isUser ? colorScheme.primary : colorScheme.surfaceContainerHighest;
    final textColor = _isUser ? colorScheme.onPrimary : colorScheme.onSurface;

    return Padding(
      padding: EdgeInsets.only(
        top: 4,
        bottom: 4,
        left: _isUser ? 48 : 0,
        right: _isUser ? 0 : 48,
      ),
      child: Align(
        alignment: _isUser ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(16),
              topRight: const Radius.circular(16),
              bottomLeft: Radius.circular(_isUser ? 16 : 4),
              bottomRight: Radius.circular(_isUser ? 4 : 16),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Flexible(
                child: Text(
                  message.content.isEmpty && isStreaming ? '…' : message.content,
                  style: TextStyle(color: textColor, fontSize: 15),
                ),
              ),
              if (isStreaming) ...[
                const SizedBox(width: 4),
                _BlinkingCursor(color: textColor),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Animated blinking cursor shown during streaming generation.
class _BlinkingCursor extends StatefulWidget {
  final Color color;
  const _BlinkingCursor({required this.color});

  @override
  State<_BlinkingCursor> createState() => _BlinkingCursorState();
}

class _BlinkingCursorState extends State<_BlinkingCursor>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    )..repeat(reverse: true);
    _opacity = CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _opacity,
      child: Container(width: 2, height: 14, color: widget.color),
    );
  }
}
