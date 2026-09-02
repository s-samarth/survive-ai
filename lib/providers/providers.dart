import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/database_service.dart';
import '../services/embedding_service.dart';
import '../services/embedding/embedder_bootstrap.dart';
import '../services/embedding/encoder_download.dart';
import '../models/doc_manifest.dart';
import '../services/embedding/vector_index.dart';
import '../services/llm_service.dart';
import '../services/chunker_service.dart';
import '../services/chat_turn_service.dart';
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

final embedderBootstrapProvider = Provider<EmbedderBootstrap>((ref) {
  return const EmbedderBootstrap();
});

/// The passage vectors that shipped with the app, loaded once.
///
/// Null when the artifact is absent, which disables the dense leg rather than
/// the app.
final vectorIndexProvider = FutureProvider<VectorIndex?>((ref) {
  return ref.watch(embedderBootstrapProvider).loadVectors();
});

/// The query encoder.
///
/// Starts as the disabled base service and is replaced once the ONNX session
/// opens, which takes seconds over a 175 MB memory-mapped graph. Holding the
/// first turn behind that would be the wrong trade in an emergency: the
/// lexical legs answer immediately, and the dense leg joins when it is ready.
final embeddingServiceProvider = StateProvider<EmbeddingService>((ref) {
  return EmbeddingService();
});

/// Opens the encoder in the background and swaps it in.
///
/// Watched for its side effect; everything downstream reads
/// [embeddingServiceProvider] and rebuilds when it changes.
final embedderLoaderProvider = FutureProvider<void>((ref) async {
  final vectors = await ref.watch(vectorIndexProvider.future);
  final embedder = await ref.watch(embedderBootstrapProvider).load(vectors);
  if (embedder.isEnabled) {
    ref.read(embeddingServiceProvider.notifier).state = embedder;
  }
});

/// Whether the encoder is already on disk.
final encoderInstalledProvider = FutureProvider<bool>((ref) {
  return ref.watch(embedderBootstrapProvider).isDownloaded();
});

/// Which files to fetch for the encoder.
///
/// The manifest wins when it names them, so the encoder can be swapped without
/// shipping an APK — the same rule the generator follows. The compiled-in
/// fallback covers a build whose manifest predates the dense leg.
final encoderFilesProvider = FutureProvider<List<ModelInfo>>((ref) async {
  final manifest = await ref.watch(syncServiceProvider).fetchManifest();
  final fromManifest = manifest?.embedder ?? const <ModelInfo>[];
  return fromManifest.isNotEmpty ? fromManifest : EncoderDownload.fallback;
});

final ragServiceProvider = Provider<RagService>((ref) {
  final db = ref.watch(databaseServiceProvider);
  final embedder = ref.watch(embeddingServiceProvider);
  return RagService(db, embedder);
});

/// Runs one conversational turn: route, retrieve, prompt, generate, guard.
///
/// The chat screen dispatches to this and renders what comes back; none of
/// the pipeline lives in the widget.
final chatTurnServiceProvider = Provider<ChatTurnService>((ref) {
  final rag = ref.watch(ragServiceProvider);
  final llm = ref.watch(llmServiceProvider);
  return ChatTurnService(rag, llm);
});

final syncServiceProvider = Provider<SyncService>((ref) {
  final db = ref.watch(databaseServiceProvider);
  final chunker = ref.watch(chunkerServiceProvider);
  final embedder = ref.watch(embeddingServiceProvider);
  return SyncService(db, chunker, embedder);
});

// ── LLM state ────────────────────────────────────────────────────────────────

/// Whether the model has been loaded into memory and is ready for inference.
final llmReadyProvider = StateProvider<bool>((ref) => false);

/// Error message if the model failed to load.
final llmErrorProvider = StateProvider<String?>((ref) => null);

/// Loading progress during model download: 0.0–1.0. Null = not downloading.
final modelDownloadProgressProvider = StateProvider<double?>((ref) => null);
