import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'providers/providers.dart';
import 'screens/home_screen.dart';
import 'screens/disclaimer_screen.dart';
import 'screens/setup_screen.dart';
import 'services/download_service.dart';

void main() {
  runApp(
    const ProviderScope(
      child: SurviveAiApp(),
    ),
  );
}

class SurviveAiApp extends StatelessWidget {
  const SurviveAiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Survive AI',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.green[800],
        brightness: Brightness.light,
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.green[800],
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      themeMode: ThemeMode.system,
      home: const _EntryRouter(),
    );
  }
}

/// Determines the correct entry screen based on app state:
/// 1. First launch -> DisclaimerScreen
/// 2. Disclaimer accepted but no model -> SetupScreen
/// 3. Model ready -> HomeScreen (with model loading in background)
class _EntryRouter extends ConsumerStatefulWidget {
  const _EntryRouter();

  @override
  ConsumerState<_EntryRouter> createState() => _EntryRouterState();
}

class _EntryRouterState extends ConsumerState<_EntryRouter> {
  Widget? _target;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  Future<void> _resolve() async {
    final prefs = await SharedPreferences.getInstance();
    final disclaimerAccepted = prefs.getBool('disclaimer_accepted') ?? false;

    if (!disclaimerAccepted) {
      setState(() => _target = const DisclaimerScreen());
      return;
    }

    // Check if model exists
    final downloadService = DownloadService();
    final modelPath = await downloadService.getExistingFile('model.gguf', 'models');

    if (modelPath == null) {
      setState(() => _target = const SetupScreen());
      return;
    }

    // Model exists — go to home, load model in background
    setState(() => _target = const HomeScreen());
    _loadModel(modelPath);
  }

  Future<void> _loadModel(String modelPath) async {
    try {
      final llm = ref.read(llmServiceProvider);
      await llm.loadModel(modelPath);
      ref.read(llmReadyProvider.notifier).state = true;
    } catch (_) {
      // Model loading failed — user will see "AI loading…" banner
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_target == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    return _target!;
  }
}
