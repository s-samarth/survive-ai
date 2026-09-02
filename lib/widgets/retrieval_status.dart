import 'package:flutter/material.dart';

import '../models/doc_chunk.dart';

/// What the app is reading, shown while the model is still thinking.
///
/// Time to first token is ~6 seconds on a laptop and slower on a 6 GB phone,
/// because the whole 1300-token prompt is processed before a single word
/// appears. Six seconds of nothing reads as a hang. Naming the guide being
/// consulted turns dead air into evidence that the answer is grounded — and
/// it is information the user genuinely wants, since it says where the advice
/// is about to come from.
class RetrievalStatus extends StatelessWidget {
  const RetrievalStatus({super.key, required this.chunks});

  final List<DocChunk> chunks;

  @override
  Widget build(BuildContext context) {
    if (chunks.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final first = chunks.first;
    final source = first.headingPath.isNotEmpty
        ? first.headingPath
        : first.topic;
    final others = chunks.length - 1;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Row(
        children: [
          Icon(
            Icons.menu_book_outlined,
            size: 14,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              others > 0 ? 'Reading $source, +$others more' : 'Reading $source',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
