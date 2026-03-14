import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/action_plan.dart';
import '../providers/providers.dart';
import 'chat_screen.dart';

/// Displays a persistent, prioritized action plan generated from situation assessment.
///
/// Steps can be marked complete — state is persisted in SQLite.
/// The plan survives app kills and reopens.
class ActionPlanScreen extends ConsumerStatefulWidget {
  final ActionPlan plan;
  const ActionPlanScreen({super.key, required this.plan});

  @override
  ConsumerState<ActionPlanScreen> createState() => _ActionPlanScreenState();
}

class _ActionPlanScreenState extends ConsumerState<ActionPlanScreen> {
  late List<ActionStep> _steps;

  @override
  void initState() {
    super.initState();
    _steps = List.from(widget.plan.steps);
  }

  Future<void> _toggleStep(int index) async {
    final step = _steps[index];
    final db = ref.read(databaseServiceProvider);

    setState(() {
      step.isCompleted = !step.isCompleted;
      step.completedAt = step.isCompleted ? DateTime.now() : null;
    });

    if (step.isCompleted) {
      await db.markStepCompleted(step.id);
    }
  }

  Color _priorityColor(StepPriority priority) => switch (priority) {
        StepPriority.critical => Colors.red[700]!,
        StepPriority.high => Colors.orange[700]!,
        StepPriority.medium => Colors.blue[700]!,
      };

  String _priorityLabel(StepPriority priority) => switch (priority) {
        StepPriority.critical => 'CRITICAL',
        StepPriority.high => 'HIGH',
        StepPriority.medium => 'MEDIUM',
      };

  @override
  Widget build(BuildContext context) {
    final completedCount = _steps.where((s) => s.isCompleted).length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Your Survival Plan'),
        leading: BackButton(onPressed: () => Navigator.pop(context)),
      ),
      body: Column(
        children: [
          // Progress summary
          Container(
            padding: const EdgeInsets.all(16),
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Row(
              children: [
                Expanded(
                  child: LinearProgressIndicator(
                    value: _steps.isEmpty ? 0 : completedCount / _steps.length,
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  '$completedCount / ${_steps.length}',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
              ],
            ),
          ),
          // Step list
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: _steps.length,
              itemBuilder: (context, index) {
                final step = _steps[index];
                return _StepCard(
                  step: step,
                  priorityColor: _priorityColor(step.priority),
                  priorityLabel: _priorityLabel(step.priority),
                  onToggle: () => _toggleStep(index),
                  onAskAi: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => Scaffold(
                        appBar: AppBar(title: Text('Ask about: ${step.title}')),
                        body: const ChatScreen(),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _StepCard extends StatelessWidget {
  final ActionStep step;
  final Color priorityColor;
  final String priorityLabel;
  final VoidCallback onToggle;
  final VoidCallback onAskAi;

  const _StepCard({
    required this.step,
    required this.priorityColor,
    required this.priorityLabel,
    required this.onToggle,
    required this.onAskAi,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: priorityColor.withAlpha(30),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: priorityColor, width: 1),
                  ),
                  child: Text(
                    priorityLabel,
                    style: TextStyle(
                      color: priorityColor,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const Spacer(),
                Checkbox(
                  value: step.isCompleted,
                  onChanged: (_) => onToggle(),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              step.title,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    decoration: step.isCompleted ? TextDecoration.lineThrough : null,
                    color: step.isCompleted ? Colors.grey : null,
                  ),
            ),
            const SizedBox(height: 4),
            Text(
              step.detail,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: step.isCompleted ? Colors.grey : null,
                  ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: onAskAi,
                icon: const Icon(Icons.chat_bubble_outline, size: 16),
                label: const Text('Ask AI about this'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
