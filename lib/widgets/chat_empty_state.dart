import 'package:flutter/material.dart';

import '../models/doc_topic.dart';

/// What the user sees before they have typed anything.
///
/// A blank chat asks someone in an emergency to compose a question. This
/// answers "what can this do?" before they have to ask it, and turns the most
/// likely situations into one-tap targets — typing is hard when your hands are
/// shaking, and the eval's own worst slice is terse, panicked input.
class ChatEmptyState extends StatelessWidget {
  const ChatEmptyState({super.key, required this.onPickTopic});

  /// Called with a ready-made opening question for the chosen situation.
  final ValueChanged<String> onPickTopic;

  /// The situations offered as chips.
  ///
  /// Ordered by how often they are the reason someone opens this app at all,
  /// not by the order of the guides.
  static const _quickTopics = <DocTopic>[
    DocTopic.medical,
    DocTopic.bites,
    DocTopic.fire,
    DocTopic.flood,
    DocTopic.earthquake,
    DocTopic.crowd,
    DocTopic.blackout,
    DocTopic.unrest,
  ];

  static String _opener(DocTopic topic) => switch (topic) {
    DocTopic.medical => 'someone is injured, what do I do first',
    DocTopic.bites => 'someone has been bitten by a snake',
    DocTopic.fire => 'there is a fire',
    DocTopic.flood => 'water is rising where I am',
    DocTopic.earthquake => 'earthquake right now, what do I do',
    DocTopic.crowd => 'I am stuck in a crowd and it is getting tight',
    DocTopic.blackout => 'there is no network or power',
    DocTopic.unrest => 'there is violence outside',
    _ => topic.displayName,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 32, 20, 16),
      children: [
        Icon(
          Icons.health_and_safety_outlined,
          size: 40,
          color: theme.colorScheme.primary,
        ),
        const SizedBox(height: 16),
        Text(
          'Offline emergency guide for India',
          style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Text(
          'No network, no SIM, no internet needed. Tell me what is happening '
          'and I will give you the steps — with the guide paragraph they came '
          'from. You can type in English or Hinglish.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 24),
        Text(
          'WHAT IS HAPPENING?',
          style: theme.textTheme.labelSmall?.copyWith(
            letterSpacing: 1.1,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final topic in _quickTopics)
              ActionChip(
                label: Text(topic.displayName),
                onPressed: () => onPickTopic(_opener(topic)),
              ),
          ],
        ),
        const SizedBox(height: 28),
        Row(
          children: [
            Icon(Icons.call, size: 16, color: theme.colorScheme.error),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Life-threatening emergency? Call 112 first if you have signal.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
