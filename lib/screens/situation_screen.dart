import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../models/action_plan.dart';
import '../models/situation.dart';
import '../providers/providers.dart';
import '../services/situation_assessor.dart';
import '../utils/prompt_builder.dart';
import 'action_plan_screen.dart';

const _uuid = Uuid();

/// 5-question guided interview to assess the user's survival situation.
///
/// After the last answer, calls LLM to extract structured situation data,
/// retrieves relevant docs via RAG, and generates a prioritized action plan.
class SituationScreen extends ConsumerStatefulWidget {
  const SituationScreen({super.key});

  @override
  ConsumerState<SituationScreen> createState() => _SituationScreenState();
}

class _SituationScreenState extends ConsumerState<SituationScreen> {
  final _assessor = SituationAssessor();
  final _controller = TextEditingController();
  bool _isProcessing = false;
  String _processingStatus = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submitAnswer() {
    final answer = _controller.text.trim();
    if (answer.isEmpty) return;

    _assessor.recordAnswer(answer);
    _controller.clear();

    if (_assessor.isDone) {
      _generatePlan();
    } else {
      setState(() {});
    }
  }

  Future<void> _generatePlan() async {
    setState(() {
      _isProcessing = true;
      _processingStatus = 'Analyzing your situation…';
    });

    try {
      final llm = ref.read(llmServiceProvider);
      final rag = ref.read(ragServiceProvider);
      final db = ref.read(databaseServiceProvider);

      final rawDescription = _assessor.buildRawDescription();

      // Step 1: Extract structured situation JSON from LLM
      setState(() => _processingStatus = 'Understanding your situation…');
      final extractionPrompt = PromptBuilder.buildSituationExtractionPrompt(rawDescription);
      final extractionBuffer = StringBuffer();
      await for (final token in llm.chat(prompt: extractionPrompt)) {
        extractionBuffer.write(token);
      }

      // Parse the situation JSON
      final situation = _parseSituation(extractionBuffer.toString(), rawDescription);

      // Step 2: Retrieve relevant docs based on situation
      setState(() => _processingStatus = 'Finding relevant survival guides…');
      final topics = situation.relevantTopics;
      final chunks = await rag.retrieveForSituation(rawDescription, topics);

      // Step 3: Generate action plan
      setState(() => _processingStatus = 'Creating your survival plan…');
      final planPrompt = PromptBuilder.buildActionPlanPrompt(
        situationSummary: rawDescription,
        chunks: chunks,
      );
      final planBuffer = StringBuffer();
      await for (final token in llm.chat(prompt: planPrompt)) {
        planBuffer.write(token);
      }

      // Parse action plan steps
      final planId = _uuid.v4();
      final steps = _parseActionSteps(planBuffer.toString(), planId);

      final plan = ActionPlan(
        id: planId,
        createdAt: DateTime.now(),
        situationJson: situation.toJson(),
        steps: steps,
      );

      // Deactivate any existing plan, then save this one
      await db.saveActionPlan(plan);

      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => ActionPlanScreen(plan: plan)),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isProcessing = false;
          _processingStatus = '';
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Situation _parseSituation(String llmResponse, String rawDescription) {
    try {
      // Extract JSON from LLM response (may contain extra text)
      final jsonMatch = RegExp(r'\{[^{}]*\}').firstMatch(llmResponse);
      if (jsonMatch != null) {
        final json = jsonDecode(jsonMatch.group(0)!) as Map<String, dynamic>;
        json['raw_description'] = rawDescription;
        return Situation.fromJson(json);
      }
    } catch (_) {
      // Fall through to default
    }
    // Fallback: create a basic situation from raw description
    return Situation(
      environment: 'unknown',
      injuries: [],
      resources: [],
      companions: 0,
      primaryGoal: 'other',
      urgency: 'high',
      rawDescription: rawDescription,
    );
  }

  List<ActionStep> _parseActionSteps(String llmResponse, String planId) {
    final steps = <ActionStep>[];
    // Parse lines like: "1. [PRIORITY: CRITICAL] Title — Detail"
    final stepRegex = RegExp(
      r'(\d+)\.\s*\[(?:PRIORITY:\s*)?(CRITICAL|HIGH|MEDIUM)\]\s*(.+?)(?:\s*[—–-]\s*(.+))?$',
      multiLine: true,
      caseSensitive: false,
    );

    for (final match in stepRegex.allMatches(llmResponse)) {
      final index = int.tryParse(match.group(1)!) ?? steps.length;
      final priorityStr = match.group(2)!.toLowerCase();
      final title = match.group(3)?.trim() ?? 'Action step';
      final detail = match.group(4)?.trim() ?? title;

      final priority = switch (priorityStr) {
        'critical' => StepPriority.critical,
        'high' => StepPriority.high,
        _ => StepPriority.medium,
      };

      steps.add(ActionStep(
        id: _uuid.v4(),
        planId: planId,
        stepIndex: index - 1,
        priority: priority,
        title: title,
        detail: detail,
      ));
    }

    // Fallback: if regex didn't match, create generic steps from numbered lines
    if (steps.isEmpty) {
      final lines = llmResponse.split('\n').where((l) => l.trim().isNotEmpty).toList();
      for (var i = 0; i < lines.length && i < 10; i++) {
        final line = lines[i].replaceFirst(RegExp(r'^\d+\.\s*'), '').trim();
        if (line.isEmpty) continue;
        steps.add(ActionStep(
          id: _uuid.v4(),
          planId: planId,
          stepIndex: i,
          priority: i < 2 ? StepPriority.critical : i < 4 ? StepPriority.high : StepPriority.medium,
          title: line.length > 60 ? '${line.substring(0, 60)}…' : line,
          detail: line,
        ));
      }
    }

    return steps;
  }

  @override
  Widget build(BuildContext context) {
    final question = _assessor.currentQuestion;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Assess Situation'),
        leading: BackButton(onPressed: () => Navigator.pop(context)),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: _isProcessing
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 16),
                    Text(_processingStatus),
                  ],
                ),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LinearProgressIndicator(
                    value: _assessor.progress / _assessor.total,
                    backgroundColor: Colors.grey[200],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Question ${_assessor.progress + 1} of ${_assessor.total}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 24),
                  Text(
                    question?.text ?? '',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  if (question?.hint.isNotEmpty == true) ...[
                    const SizedBox(height: 8),
                    Text(
                      question!.hint,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.grey[600]),
                    ),
                  ],
                  const SizedBox(height: 24),
                  TextField(
                    controller: _controller,
                    autofocus: true,
                    maxLines: 3,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _submitAnswer(),
                    decoration: InputDecoration(
                      hintText: 'Your answer…',
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _submitAnswer,
                      child: Text(
                        _assessor.progress + 1 == _assessor.total ? 'Analyze Situation' : 'Next',
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
