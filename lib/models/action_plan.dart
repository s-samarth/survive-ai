/// Priority levels for action steps, ordered from most to least urgent.
enum StepPriority { critical, high, medium }

/// A single step in an action plan.
class ActionStep {
  final String id;
  final String planId;
  final int stepIndex;
  final StepPriority priority;
  final String title;
  final String detail;
  final String? sourceDocId;
  bool isCompleted;
  DateTime? completedAt;

  ActionStep({
    required this.id,
    required this.planId,
    required this.stepIndex,
    required this.priority,
    required this.title,
    required this.detail,
    this.sourceDocId,
    this.isCompleted = false,
    this.completedAt,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'plan_id': planId,
        'step_index': stepIndex,
        'priority': priority.name,
        'title': title,
        'detail': detail,
        'source_doc_id': sourceDocId,
        'is_completed': isCompleted ? 1 : 0,
        'completed_at': completedAt?.millisecondsSinceEpoch,
      };

  factory ActionStep.fromMap(Map<String, dynamic> map) => ActionStep(
        id: map['id'] as String,
        planId: map['plan_id'] as String,
        stepIndex: map['step_index'] as int,
        priority: StepPriority.values.firstWhere((p) => p.name == map['priority']),
        title: map['title'] as String,
        detail: map['detail'] as String,
        sourceDocId: map['source_doc_id'] as String?,
        isCompleted: (map['is_completed'] as int) == 1,
        completedAt: map['completed_at'] != null
            ? DateTime.fromMillisecondsSinceEpoch(map['completed_at'] as int)
            : null,
      );
}

/// A full survival action plan generated from situation assessment.
class ActionPlan {
  final String id;
  final DateTime createdAt;
  final Map<String, dynamic> situationJson;
  final List<ActionStep> steps;
  final bool isActive;

  const ActionPlan({
    required this.id,
    required this.createdAt,
    required this.situationJson,
    required this.steps,
    this.isActive = true,
  });
}
