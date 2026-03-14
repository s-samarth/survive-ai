import 'package:flutter/material.dart';
import 'chat_screen.dart';

/// Displays step-by-step guidance one step at a time.
///
/// Generated when the user's intent is classified as GUIDE.
/// Each step is shown individually with Next/Back navigation.
class StepGuideScreen extends StatefulWidget {
  final String title;
  final List<String> steps;
  final String? topic;

  const StepGuideScreen({
    super.key,
    required this.title,
    required this.steps,
    this.topic,
  });

  @override
  State<StepGuideScreen> createState() => _StepGuideScreenState();
}

class _StepGuideScreenState extends State<StepGuideScreen> {
  int _currentStep = 0;

  @override
  Widget build(BuildContext context) {
    final step = widget.steps[_currentStep];

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        leading: BackButton(onPressed: () => Navigator.pop(context)),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Progress
            LinearProgressIndicator(
              value: (_currentStep + 1) / widget.steps.length,
            ),
            const SizedBox(height: 8),
            Text(
              'Step ${_currentStep + 1} of ${widget.steps.length}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 24),

            // Step content
            Expanded(
              child: SingleChildScrollView(
                child: Text(
                  step,
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.6),
                ),
              ),
            ),

            // Navigation buttons
            const SizedBox(height: 16),
            Row(
              children: [
                if (_currentStep > 0)
                  OutlinedButton.icon(
                    onPressed: () => setState(() => _currentStep--),
                    icon: const Icon(Icons.arrow_back, size: 18),
                    label: const Text('Back'),
                  ),
                const Spacer(),
                TextButton.icon(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => Scaffold(
                        appBar: AppBar(title: const Text('Tell me more')),
                        body: ChatScreen(topicFilter: widget.topic),
                      ),
                    ),
                  ),
                  icon: const Icon(Icons.chat_bubble_outline, size: 16),
                  label: const Text('Tell me more'),
                ),
                const SizedBox(width: 8),
                if (_currentStep < widget.steps.length - 1)
                  FilledButton.icon(
                    onPressed: () => setState(() => _currentStep++),
                    icon: const Icon(Icons.arrow_forward, size: 18),
                    label: const Text('Next'),
                  )
                else
                  FilledButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Done'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
