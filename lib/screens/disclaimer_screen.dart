import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'setup_screen.dart';

/// Shown once on first launch. User must acknowledge the disclaimer
/// before proceeding to model download and app setup.
class DisclaimerScreen extends StatelessWidget {
  const DisclaimerScreen({super.key});

  Future<void> _accept(BuildContext context) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('disclaimer_accepted', true);
    if (context.mounted) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const SetupScreen()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.crisis_alert, size: 64, color: Colors.red[700]),
              const SizedBox(height: 24),
              Text(
                'Survive AI',
                style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 24),
              Text(
                'This app provides general survival guidance only.\n\n'
                'It is NOT a substitute for professional medical care, '
                'emergency services, or trained responders.\n\n'
                'Always seek professional help when available. '
                'Do not rely solely on this app in life-threatening situations.\n\n'
                'No specific medication dosages are provided. '
                'Information is for general guidance only.',
                style: Theme.of(context).textTheme.bodyLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () => _accept(context),
                  icon: const Icon(Icons.check),
                  label: const Text('I Understand'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
