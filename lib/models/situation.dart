/// Structured description of a user's survival situation,
/// extracted from the 5-question assessment interview.
class Situation {
  final String environment; // jungle | desert | urban | coastal | mountain | unknown
  final List<String> injuries; // e.g. ["broken_leg", "dehydration"]
  final List<String> resources; // e.g. ["water", "fire", "shelter"]
  final int companions; // 0 = alone
  final String primaryGoal; // escape | shelter | medical | rescue_signal | other
  final String urgency; // critical | high | medium | low
  final String rawDescription; // free-text summary for display

  const Situation({
    required this.environment,
    required this.injuries,
    required this.resources,
    required this.companions,
    required this.primaryGoal,
    required this.urgency,
    required this.rawDescription,
  });

  Map<String, dynamic> toJson() => {
        'environment': environment,
        'injuries': injuries,
        'resources': resources,
        'companions': companions,
        'primary_goal': primaryGoal,
        'urgency': urgency,
        'raw_description': rawDescription,
      };

  factory Situation.fromJson(Map<String, dynamic> json) => Situation(
        environment: json['environment'] as String? ?? 'unknown',
        injuries: List<String>.from(json['injuries'] as List? ?? []),
        resources: List<String>.from(json['resources'] as List? ?? []),
        companions: json['companions'] as int? ?? 0,
        primaryGoal: json['primary_goal'] as String? ?? 'other',
        urgency: json['urgency'] as String? ?? 'high',
        rawDescription: json['raw_description'] as String? ?? '',
      );

  /// Topic filters derived from the situation, used to scope RAG retrieval.
  List<String> get relevantTopics {
    final topics = <String>[];
    if (['jungle', 'desert', 'mountain', 'coastal'].contains(environment)) {
      topics.add(environment);
    }
    if (injuries.isNotEmpty) topics.add('medical');
    if (['war', 'urban'].contains(environment)) topics.add('war');
    topics.add('general');
    return topics;
  }
}
