import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/providers.dart';

/// Banner that appears when new docs are available to sync.
///
/// Shown at the top of the home screen when WiFi is available
/// and the manifest version differs from local.
class SyncStatusBanner extends ConsumerStatefulWidget {
  const SyncStatusBanner({super.key});

  @override
  ConsumerState<SyncStatusBanner> createState() => _SyncStatusBannerState();
}

class _SyncStatusBannerState extends ConsumerState<SyncStatusBanner> {
  bool _visible = false;
  bool _syncing = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _checkForUpdates();
  }

  Future<void> _checkForUpdates() async {
    try {
      final syncService = ref.read(syncServiceProvider);
      final status = await syncService.checkForUpdates();
      if (status.name == 'updatesAvailable' && mounted) {
        setState(() {
          _visible = true;
          _message = 'New survival docs available';
        });
      }
    } catch (_) {
      // Silent — don't show banner if check fails
    }
  }

  Future<void> _syncNow() async {
    setState(() {
      _syncing = true;
      _message = 'Syncing…';
    });

    try {
      final syncService = ref.read(syncServiceProvider);
      final result = await syncService.syncNow();
      setState(() {
        _syncing = false;
        _message = result.updatedDocs > 0
            ? 'Updated ${result.updatedDocs} docs'
            : 'Up to date';
      });

      // Hide after a delay
      await Future.delayed(const Duration(seconds: 3));
      if (mounted) setState(() => _visible = false);
    } catch (_) {
      setState(() {
        _syncing = false;
        _message = 'Sync failed';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_visible) return const SizedBox.shrink();

    return Container(
      color: Theme.of(context).colorScheme.primaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Icon(
            Icons.cloud_download_outlined,
            size: 16,
            color: Theme.of(context).colorScheme.onPrimaryContainer,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _message ?? '',
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).colorScheme.onPrimaryContainer,
              ),
            ),
          ),
          if (!_syncing)
            TextButton(onPressed: _syncNow, child: const Text('Sync'))
          else
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
        ],
      ),
    );
  }
}
