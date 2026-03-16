import 'dart:math';
import 'package:flutter/material.dart';
import '../models/chat_message.dart';

/// A single chat message bubble.
///
/// User messages appear right-aligned in a filled bubble.
/// Assistant messages appear left-aligned in a surface-colored bubble.
///
/// While [isStreaming] is true and no content has arrived yet, a three-dot
/// typing indicator is shown (like ChatGPT / iMessage). Once tokens begin
/// streaming in, text is displayed with a blinking cursor at the end.
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

    final showTypingIndicator = isStreaming && message.content.isEmpty;
    final showCursor = isStreaming && message.content.isNotEmpty;

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
          child: showTypingIndicator
              ? _TypingIndicator(color: textColor)
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Flexible(
                      child: Text(
                        message.content,
                        style: TextStyle(color: textColor, fontSize: 15),
                      ),
                    ),
                    if (showCursor) ...[
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

/// Animated three-dot typing indicator shown while waiting for the first token.
///
/// Each dot bounces up in a staggered wave (delays: 0 ms, 150 ms, 300 ms),
/// matching the visual pattern used by ChatGPT, WhatsApp, and iMessage.
class _TypingIndicator extends StatefulWidget {
  final Color color;
  const _TypingIndicator({required this.color});

  @override
  State<_TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<_TypingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 20,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _BounceDot(controller: _ctrl, delay: 0.00, color: widget.color),
          const SizedBox(width: 5),
          _BounceDot(controller: _ctrl, delay: 0.15, color: widget.color),
          const SizedBox(width: 5),
          _BounceDot(controller: _ctrl, delay: 0.30, color: widget.color),
        ],
      ),
    );
  }
}

class _BounceDot extends StatelessWidget {
  final AnimationController controller;
  final double delay;
  final Color color;

  const _BounceDot({
    required this.controller,
    required this.delay,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, child) {
        // Normalise to [0,1) with stagger, then compute a half-sine bounce so
        // the dot rises smoothly in the first half and rests in the second half.
        final t = ((controller.value - delay) % 1.0 + 1.0) % 1.0;
        final bounce = t < 0.5 ? sin(t * pi * 2) : 0.0;
        return Transform.translate(
          offset: Offset(0, -bounce * 5),
          child: child,
        );
      },
      child: Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
    );
  }
}

/// Animated blinking cursor shown while tokens are still streaming in.
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
