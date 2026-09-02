import 'package:flutter/material.dart';

/// The message composer at the foot of the chat.
///
/// Disabled while the model loads or generates, because a second question
/// mid-answer would queue behind a ~27-second turn on this hardware.
class ChatInputBar extends StatelessWidget {
  final TextEditingController controller;
  final bool enabled;
  final VoidCallback onSend;

  const ChatInputBar({
    super.key,
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
                  hintText: enabled
                      ? 'Ask a survival question…'
                      : 'Loading AI…',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
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
