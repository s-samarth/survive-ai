import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'providers/providers.dart';
import 'screens/home_screen.dart';
import 'screens/disclaimer_screen.dart';
import 'services/download_service.dart';
import 'services/llm_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await FlutterGemma.initialize();

  // Use the FFI backend on all platforms to guarantee FTS5 support
  // (via the sqlite3_flutter_libs native binaries) rather than relying
  // on the system's built-in SQLite which might lack extensions.
  if (Platform.isAndroid ||
      Platform.isIOS ||
      Platform.isWindows ||
      Platform.isLinux ||
      Platform.isMacOS) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

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

/// Determines the correct entry screen:
/// 1. First launch (disclaimer not yet accepted) → DisclaimerScreen
/// 2. Disclaimer accepted → HomeScreen always
///    - If the model file exists on disk, load it in the background
///    - If not found, HomeScreen shows a download banner
///
/// Model detection uses [DownloadService.findModelFile] which checks the
/// physical file on disk — not just SharedPreferences metadata. This avoids
/// the stale-state bug where flutter_gemma's isModelInstalled() returns true
/// even when the file was never fully downloaded.
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

    // Always go to HomeScreen — it handles the model-missing case itself
    setState(() => _target = const HomeScreen());

    // Find the model file on disk (checks all known locations)
    final modelPath =
        await DownloadService().findModelFile(kModelName);
    if (modelPath != null) {
      // If the previous load attempt was killed by the OS (OOM / SIGKILL),
      // the 'model_load_pending' flag is still set. Don't retry automatically —
      // let HomeScreen show the repair banner so the user can decide.
      final prefs = await SharedPreferences.getInstance();
      final prevCrashed = prefs.getBool('model_load_pending') ?? false;
      if (prevCrashed) return;

      // Set the flag BEFORE loading. If the process is killed mid-load,
      // this persists and HomeScreen detects the crash on next launch.
      await prefs.setBool('model_load_pending', true);
      _loadModel(modelPath);
    }
  }

  Future<void> _loadModel(String modelPath) async {
    try {
      final llm = ref.read(llmServiceProvider);
      await llm.loadModel(modelPath);
      ref.read(llmReadyProvider.notifier).state = true;
      ref.read(llmErrorProvider.notifier).state = null;
      // Clear the crash-detection flag — load succeeded.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('model_load_pending', false);
    } catch (e, st) {
      debugPrint('CRITICAL: Failed to load model in background: $e');
      debugPrint('$st');
      ref.read(llmErrorProvider.notifier).state = e.toString();
      // Clear the crash-detection flag — we reached the catch block, so
      // this is a normal exception (not an OOM/SIGKILL). Leaving the flag
      // set would incorrectly show the repair banner on next launch.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('model_load_pending', false);
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
