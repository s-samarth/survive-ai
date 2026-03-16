import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/database_service.dart';
import '../services/llm_service.dart';
import '../services/chunker_service.dart';
import '../services/rag_service.dart';
import '../services/sync_service.dart';

// ── Singleton service providers ──────────────────────────────────────────────

final databaseServiceProvider = Provider<DatabaseService>((ref) {
  final service = DatabaseService();
  ref.onDispose(service.dispose);
  return service;
});

final llmServiceProvider = Provider<LlmService>((ref) {
  final service = LlmService();
  ref.onDispose(service.disposeAsync);
  return service;
});

final chunkerServiceProvider = Provider<ChunkerService>((ref) {
  return const ChunkerService();
});

final ragServiceProvider = Provider<RagService>((ref) {
  final db = ref.watch(databaseServiceProvider);
  return RagService(db);
});

final syncServiceProvider = Provider<SyncService>((ref) {
  final db = ref.watch(databaseServiceProvider);
  final chunker = ref.watch(chunkerServiceProvider);
  return SyncService(db, chunker);
});

// ── LLM state ────────────────────────────────────────────────────────────────

/// Whether the model has been loaded into memory and is ready for inference.
final llmReadyProvider = StateProvider<bool>((ref) => false);

/// Error message if the model failed to load.
final llmErrorProvider = StateProvider<String?>((ref) => null);

/// Loading progress during model download: 0.0–1.0. Null = not downloading.
final modelDownloadProgressProvider = StateProvider<double?>((ref) => null);
