import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../providers/providers.dart';
import '../services/download_service.dart';
import '../services/llm_service.dart';
import 'home_screen.dart';

const _modelUrl =
    'https://huggingface.co/ASahu16/gemma/resolve/main/gemma-2b-it-cpu-int4.bin';
const _modelSizeBytes = 1350000000;

/// Handles first-launch setup: WiFi check → model download → doc sync.
///
/// Also used when the model file is missing or corrupted (via the "Repair"
/// button in ChatScreen). Model presence is checked by looking for the
/// physical file on disk — not SharedPreferences metadata — so stale
/// flutter_gemma state does not cause a false "already installed" skip.
class SetupScreen extends ConsumerStatefulWidget {
  const SetupScreen({super.key});

  @override
  ConsumerState<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends ConsumerState<SetupScreen> {
  _SetupPhase _phase = _SetupPhase.checkingConnectivity;
  String _statusText = 'Checking connectivity…';
  double _progress = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _startSetup();
  }

  Future<void> _startSetup() async {
    setState(() {
      _phase = _SetupPhase.checkingConnectivity;
      _statusText = 'Checking connectivity…';
      _error = null;
    });

    // Check if the model file physically exists on disk
    final existingPath =
        await DownloadService().findModelFile(kModelName);
    if (existingPath != null) {
      // File is on disk — just activate and load it
      await _loadModelAndProceed(existingPath);
      return;
    }

    // Need internet to download the model
    final connectivity = await Connectivity().checkConnectivity();
    final hasInternet = connectivity.any((r) => r != ConnectivityResult.none);

    if (!hasInternet) {
      setState(() {
        _phase = _SetupPhase.waitingForWifi;
        _statusText =
            'Connect to WiFi to download the AI model.\nThis is a one-time ~1.3 GB download.';
      });
      return;
    }

    await _downloadModel();
  }

  Future<void> _downloadModel() async {
    try {
      // ── Download ──────────────────────────────────────────────────────────
      setState(() {
        _phase = _SetupPhase.downloadingModel;
        _statusText = 'Downloading AI model…';
        _progress = 0;
      });

      final downloader = DownloadService();
      final localPath = await downloader.download(
        url: _modelUrl,
        filename: kModelName,
        subfolder: 'models',
        expectedBytes: _modelSizeBytes,
        onProgress: (done, total) {
          if (total > 0) setState(() => _progress = done / total);
        },
      );

      // ── Seed & sync docs (non-fatal) ──────────────────────────────────────
      setState(() {
        _phase = _SetupPhase.syncingDocs;
        _statusText = 'Initializing survival guides…';
        _progress = 0;
      });

      final syncService = ref.read(syncServiceProvider);
      try {
        await syncService.seedFromAssets();
        await syncService.syncNow(
          onProgress: (done, total) {
            if (total > 0) setState(() => _progress = done / total);
          },
        );
      } catch (_) {
        // Doc sync failure is non-fatal — bundled assets are seeded above.
        // The app will retry sync next time WiFi is available.
      }

      await _loadModelAndProceed(localPath);
    } catch (e) {
      setState(() {
        _phase = _SetupPhase.error;
        _error = e.toString();
        _statusText = 'Setup failed';
      });
    }
  }

  Future<void> _loadModelAndProceed(String modelPath) async {
    setState(() {
      _phase = _SetupPhase.loadingModel;
      _statusText = 'Waking up the local AI…';
      _progress = 0;
    });

    try {
      // Set crash-detection flag before loading. If the process is killed by
      // the OOM killer mid-load, the flag persists and HomeScreen shows repair.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('model_load_pending', true);

      final llm = ref.read(llmServiceProvider);
      await llm.loadModel(modelPath);

      await prefs.setBool('model_load_pending', false);
      ref.read(llmReadyProvider.notifier).state = true;
      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const HomeScreen()),
        );
      }
    } catch (e) {
      setState(() {
        _phase = _SetupPhase.error;
        _error = e.toString();
        _statusText = 'Model failed to load';
      });
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
              Icon(
                _phase == _SetupPhase.error
                    ? Icons.error_outline
                    : _phase == _SetupPhase.waitingForWifi
                        ? Icons.wifi_off
                        : Icons.downloading,
                size: 64,
                color: _phase == _SetupPhase.error
                    ? Colors.red
                    : Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 24),
              Text(
                _statusText,
                style: Theme.of(context).textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),

              // Progress bar for download/sync phases
              if (_phase == _SetupPhase.downloadingModel ||
                  _phase == _SetupPhase.syncingDocs) ...[
                LinearProgressIndicator(value: _progress),
                const SizedBox(height: 8),
                Text(
                  '${(_progress * 100).toStringAsFixed(0)}%',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],

              // Loading spinner for non-download phases
              if (_phase == _SetupPhase.checkingConnectivity ||
                  _phase == _SetupPhase.fetchingManifest ||
                  _phase == _SetupPhase.loadingModel)
                const CircularProgressIndicator(),

              // Error message
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(
                  _error!,
                  style: TextStyle(color: Colors.red[700], fontSize: 13),
                  textAlign: TextAlign.center,
                ),
              ],

              // Retry / wait button
              if (_phase == _SetupPhase.waitingForWifi ||
                  _phase == _SetupPhase.error) ...[
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: _startSetup,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

enum _SetupPhase {
  checkingConnectivity,
  waitingForWifi,
  fetchingManifest,
  downloadingModel,
  syncingDocs,
  loadingModel,
  error,
}
