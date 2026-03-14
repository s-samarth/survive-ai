import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../widgets/sync_status_banner.dart';
import 'chat_screen.dart';
import 'topic_browser_screen.dart';
import 'situation_screen.dart';
import 'settings_screen.dart';

/// Main entry screen — shown after model and docs are ready.
///
/// Three entry points:
/// 1. Chat tab — open-ended AI conversation
/// 2. Topics tab — browse survival docs by category
/// 3. "Assess My Situation" button — launch the guided assessment flow
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  int _selectedTab = 0;

  static const _tabs = [
    _TabItem(icon: Icons.chat_bubble_outline, label: 'Chat'),
    _TabItem(icon: Icons.menu_book_outlined, label: 'Topics'),
  ];

  @override
  Widget build(BuildContext context) {
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
          const SyncStatusBanner(),
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
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const SituationScreen()),
        ),
        icon: const Icon(Icons.crisis_alert),
        label: const Text('Assess Situation'),
        backgroundColor: Colors.red[700],
        foregroundColor: Colors.white,
      ),
    );
  }
}

class _TabItem {
  final IconData icon;
  final String label;
  const _TabItem({required this.icon, required this.label});
}
