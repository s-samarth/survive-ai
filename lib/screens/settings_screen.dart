import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../providers/providers.dart';

/// Displays storage info, sync status, and app configuration.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  String _storageInfo = 'Calculating…';
  String _lastSync = 'Never';
  String _manifestVersion = '—';
  bool _syncing = false;
  String? _syncMessage;

  @override
  void initState() {
    super.initState();
    _loadInfo();
  }

  Future<void> _loadInfo() async {
    final prefs = await SharedPreferences.getInstance();
    final lastSyncMs = prefs.getInt('last_sync_ms');
    final version = prefs.getString('manifest_version') ?? '—';

    String lastSync = 'Never';
    if (lastSyncMs != null) {
      final dt = DateTime.fromMillisecondsSinceEpoch(lastSyncMs);
      lastSync = '${dt.year}-${_pad(dt.month)}-${_pad(dt.day)} at ${_pad(dt.hour)}:${_pad(dt.minute)}';
    }

    // Calculate storage
    final appDir = await getApplicationDocumentsDirectory();
    final modelSize = await _fileSize('${appDir.path}/models/model.gguf');
    final docsSize = await _dirSize(Directory('${appDir.path}/docs'));
    final dbSize = await _fileSize('${appDir.path}/survive_ai.db');
    final totalMb = (modelSize + docsSize + dbSize) / (1024 * 1024);

    setState(() {
      _storageInfo = '${totalMb.toStringAsFixed(0)} MB total '
          '(model: ${(modelSize / (1024 * 1024)).toStringAsFixed(0)} MB, '
          'docs: ${(docsSize / (1024 * 1024)).toStringAsFixed(1)} MB, '
          'DB: ${(dbSize / (1024 * 1024)).toStringAsFixed(1)} MB)';
      _lastSync = lastSync;
      _manifestVersion = version;
    });
  }

  Future<void> _syncNow() async {
    setState(() {
      _syncing = true;
      _syncMessage = 'Syncing…';
    });

    try {
      final syncService = ref.read(syncServiceProvider);
      final result = await syncService.syncNow(
        onProgress: (done, total) {
          setState(() => _syncMessage = 'Syncing… $done / $total docs');
        },
      );

      setState(() {
        _syncing = false;
        _syncMessage = result.updatedDocs > 0
            ? 'Synced ${result.updatedDocs} docs'
            : 'Already up to date';
      });
      await _loadInfo();
    } catch (e) {
      setState(() {
        _syncing = false;
        _syncMessage = 'Sync failed: $e';
      });
    }
  }

  Future<int> _fileSize(String path) async {
    final file = File(path);
    if (await file.exists()) return await file.length();
    return 0;
  }

  Future<int> _dirSize(Directory dir) async {
    if (!await dir.exists()) return 0;
    int total = 0;
    await for (final entity in dir.list(recursive: true)) {
      if (entity is File) total += await entity.length();
    }
    return total;
  }

  String _pad(int n) => n.toString().padLeft(2, '0');

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          _SectionHeader(title: 'Storage'),
          ListTile(
            leading: const Icon(Icons.storage),
            title: const Text('Storage used'),
            subtitle: Text(_storageInfo),
          ),
          const Divider(),
          _SectionHeader(title: 'Sync'),
          ListTile(
            leading: const Icon(Icons.sync),
            title: const Text('Last sync'),
            subtitle: Text(_lastSync),
          ),
          ListTile(
            leading: const Icon(Icons.tag),
            title: const Text('Manifest version'),
            subtitle: Text(_manifestVersion),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: FilledButton.icon(
              onPressed: _syncing ? null : _syncNow,
              icon: _syncing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.sync),
              label: Text(_syncing ? 'Syncing…' : 'Sync Now'),
            ),
          ),
          if (_syncMessage != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                _syncMessage!,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          const Divider(),
          _SectionHeader(title: 'About'),
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('Survive AI'),
            subtitle: Text('v1.0.0 — Open-source humanitarian project'),
          ),
          const ListTile(
            leading: Icon(Icons.memory),
            title: Text('AI Model'),
            subtitle: Text('Gemma 3 1B (Q4_K_M)'),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: Theme.of(context).colorScheme.primary,
            ),
      ),
    );
  }
}
