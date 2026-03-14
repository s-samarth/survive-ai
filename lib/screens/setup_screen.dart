import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/doc_manifest.dart';
import '../providers/providers.dart';
import '../services/download_service.dart';
import 'home_screen.dart';

const _manifestUrl =
    'https://raw.githubusercontent.com/survive-ai/survive-ai-docs/main/manifest.json';

/// Handles first-launch setup: WiFi check → manifest fetch → model download → doc sync.
///
/// Also used when the model file is missing or corrupted.
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

    // Check if model already exists (skip download)
    final downloadService = DownloadService();
    final existingModel = await downloadService.getExistingFile(
      'model.gguf',
      'models',
    );

    if (existingModel != null) {
      // Model exists — load it and go
      await _loadModelAndProceed(existingModel);
      return;
    }

    // Need internet to download model
    final connectivity = await Connectivity().checkConnectivity();
    final hasInternet = connectivity.any((r) => r != ConnectivityResult.none);

    if (!hasInternet) {
      setState(() {
        _phase = _SetupPhase.waitingForWifi;
        _statusText = 'Connect to WiFi to download the AI model.\nThis is a one-time ~500MB download.';
      });
      return;
    }

    await _downloadModel();
  }

  Future<void> _downloadModel() async {
    try {
      // Fetch manifest
      setState(() {
        _phase = _SetupPhase.fetchingManifest;
        _statusText = 'Fetching latest survival data…';
      });

      final response = await http.get(Uri.parse(_manifestUrl));
      if (response.statusCode != 200) {
        throw Exception('Failed to fetch manifest (HTTP ${response.statusCode})');
      }
      final manifest = DocManifest.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>,
      );

      // Download model
      setState(() {
        _phase = _SetupPhase.downloadingModel;
        _statusText = 'Downloading AI model…';
        _progress = 0;
      });

      final downloadService = DownloadService();
      final modelPath = await downloadService.download(
        url: manifest.model.url,
        filename: 'model.gguf',
        subfolder: 'models',
        expectedSha256: manifest.model.sha256,
        expectedBytes: manifest.model.sizeBytes,
        onProgress: (downloaded, total) {
          if (total > 0) {
            setState(() => _progress = downloaded / total);
          }
        },
      );

      // Save manifest version
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('manifest_version', manifest.version);

      // Sync docs
      setState(() {
        _phase = _SetupPhase.syncingDocs;
        _statusText = 'Downloading survival docs…';
        _progress = 0;
      });

      final syncService = ref.read(syncServiceProvider);
      await syncService.syncNow(
        onProgress: (done, total) {
          if (total > 0) setState(() => _progress = done / total);
        },
      );

      // Load model
      await _loadModelAndProceed(modelPath);
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
      _statusText = 'Loading AI model…';
    });

    try {
      final llm = ref.read(llmServiceProvider);
      await llm.loadModel(modelPath);
      ref.read(llmReadyProvider.notifier).state = true;

      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const HomeScreen()),
        );
      }
    } catch (e) {
      setState(() {
        _phase = _SetupPhase.error;
        _error = 'Failed to load AI model: $e';
        _statusText = 'Setup failed';
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

              // Progress bar for download phases
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

              // Retry button
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
