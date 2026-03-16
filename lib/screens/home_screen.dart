import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../providers/providers.dart';
import '../widgets/sync_status_banner.dart';
import '../services/download_service.dart';
import '../services/llm_service.dart';
import 'chat_screen.dart';
import 'topic_browser_screen.dart';
import 'settings_screen.dart';
import 'setup_screen.dart';

/// Main entry screen.
///
/// Three entry points:
/// 1. Chat tab — open-ended AI conversation
/// 2. Topics tab — browse survival docs by category
/// 3. "Assess My Situation" FAB — launch the guided assessment flow
///
/// If the AI model has not been downloaded yet, shows a banner prompting
/// the user to set it up. The rest of the app (doc browsing) still works.
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  int _selectedTab = 0;
  bool _modelMissing = false;
  bool _modelLoadFailed = false;

  static const _tabs = [
    _TabItem(icon: Icons.chat_bubble_outline, label: 'Chat'),
    _TabItem(icon: Icons.crisis_alert_outlined, label: 'Situations'),
  ];

  @override
  void initState() {
    super.initState();
    _checkModel();
  }

  Future<void> _checkModel() async {
    final prefs = await SharedPreferences.getInstance();
    final modelPath = await DownloadService().findModelFile(kModelName);

    if (!mounted) return;

    if (modelPath == null) {
      setState(() => _modelMissing = true);
    } else if (prefs.getBool('model_load_pending') ?? false) {
      // The flag was set before a previous load attempt that never completed —
      // most likely an OOM crash (SIGKILL). Clear it and surface the repair UI.
      await prefs.setBool('model_load_pending', false);
      setState(() => _modelLoadFailed = true);
    }
  }

  Future<void> _repairModel() async {
    // Delete the existing model file and re-run setup (fresh download).
    await DownloadService().deleteFile(kModelName, 'models');
    setState(() => _modelLoadFailed = false);
    if (mounted) {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const SetupScreen()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final llmReady = ref.watch(llmReadyProvider);
    final llmError = ref.watch(llmErrorProvider);

    // Once the model is ready, hide any failure banners
    if (llmReady) {
      _modelMissing = false;
      _modelLoadFailed = false;
    }

    // llmErrorProvider is set when load throws a caught exception (not OOM).
    // _modelLoadFailed is set when load was killed by the OS (OOM / SIGKILL).
    final showRepair = _modelLoadFailed || (llmError != null && !llmReady);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Survive AI'),
        centerTitle: false,
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
            tooltip: 'Settings',
          ),
        ],
      ),
      body: Column(
        children: [
          // Repair banner — model exists but previous load failed/crashed
          if (showRepair)
            _ModelRepairBanner(onRepair: _repairModel),
          // Model download prompt — shown only when model file is absent
          if (!showRepair && _modelMissing)
            _ModelSetupBanner(onDismiss: () => setState(() => _modelMissing = false)),
          // Doc sync banner — shown when WiFi is up and new docs are available
          if (!showRepair && !_modelMissing) const SyncStatusBanner(),
          Expanded(
            child: IndexedStack(
              index: _selectedTab,
              children: const [
                ChatScreen(),
                TopicBrowserScreen(),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedTab,
        onDestinationSelected: (i) => setState(() => _selectedTab = i),
        destinations: _tabs
            .map((t) => NavigationDestination(icon: Icon(t.icon), label: t.label))
            .toList(),
      ),
    );
  }
}

/// Banner shown when a previous model load attempt failed or was killed by the OS.
///
/// Offers a "Repair" button that deletes the existing model file and re-runs
/// the setup flow for a fresh download.
class _ModelRepairBanner extends StatelessWidget {
  final VoidCallback onRepair;
  const _ModelRepairBanner({required this.onRepair});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.errorContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(
            Icons.warning_amber_outlined,
            size: 18,
            color: Theme.of(context).colorScheme.onErrorContainer,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'AI model failed to load — device may not have enough memory.',
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).colorScheme.onErrorContainer,
              ),
            ),
          ),
          TextButton(
            onPressed: onRepair,
            child: const Text('Repair'),
          ),
        ],
      ),
    );
  }
}

/// Banner shown when the AI model has not been downloaded yet.
///
/// Lets the user browse docs immediately while the model setup is deferred.
/// Tapping "Set up" navigates to SetupScreen to trigger the download.
class _ModelSetupBanner extends StatelessWidget {
  final VoidCallback onDismiss;
  const _ModelSetupBanner({required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.tertiaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(
            Icons.download_outlined,
            size: 18,
            color: Theme.of(context).colorScheme.onTertiaryContainer,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'AI model not downloaded. Connect to WiFi to set up.',
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).colorScheme.onTertiaryContainer,
              ),
            ),
          ),
          TextButton(
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SetupScreen()),
              ).then((_) => onDismiss());
            },
            child: const Text('Set up'),
          ),
        ],
      ),
    );
  }
}

class _TabItem {
  final IconData icon;
  final String label;
  const _TabItem({required this.icon, required this.label});
}
