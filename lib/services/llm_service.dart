import 'package:flutter_gemma/flutter_gemma.dart';

/// Filename used by flutter_gemma for the on-device Gemma model.
/// Must match across setup_screen, home_screen, and main.dart.
const kModelName = 'gemma-2b-it-cpu-int4.bin';

/// Total context window handed to MediaPipe, in tokens.
///
/// In flutter_gemma this single number is the **whole** budget — prompt plus
/// generated reply — not an output cap. It was previously 512, which silently
/// truncated every RAG-augmented prompt. 2048 is the largest window that keeps
/// the KV cache comfortable alongside Gemma 2B int4 on a 4-6 GB device; raise
/// it when the app moves to a LiteRT-LM model with a cheaper cache.
const kContextTokens = 2048;

/// Tokens reserved for the model's answer inside [kContextTokens].
const kReservedOutputTokens = 512;

/// Tokens a prompt may occupy. The 84-token margin absorbs the turn markers
/// flutter_gemma injects and the drift in our word-count token estimate.
const kMaxPromptTokens = kContextTokens - kReservedOutputTokens - 84;

/// Wraps flutter_gemma to provide model loading and token-streaming chat.
///
/// flutter_gemma's active-model state is in-memory only — it resets on every
/// app restart. So [loadModel] must call [FlutterGemma.installModel().fromFile().install()]
/// on every launch (not just first install). [install()] skips the file-copy
/// step when the model is already registered, so this is fast.
class LlmService {
  InferenceModel? _model;
  InferenceModelSession? _session;
  bool _isLoaded = false;
  bool _isGenerating = false;

  bool get isLoaded => _isLoaded;

  /// True while a [chat] stream is still producing tokens.
  bool get isGenerating => _isGenerating;

  /// Activate and load the Gemma model from [modelPath].
  ///
  /// [modelPath] must point to the actual .bin file on disk. Call
  /// [DownloadService.findModelFile] to locate it before calling this.
  ///
  /// This method is safe to call on every launch — flutter_gemma's
  /// [installModel().fromFile().install()] is idempotent (skips the copy if
  /// the file is already registered, but always sets the active model spec).
  Future<void> loadModel(String modelPath) async {
    if (_isLoaded) return;

    // Re-activate the model for this session. Required on every app start
    // because flutter_gemma does not persist the active-model spec across restarts.
    await FlutterGemma.installModel(
      modelType: ModelType.gemmaIt,
      fileType: ModelFileType.binary,
    ).fromFile(modelPath).install();

    _model = await FlutterGemma.getActiveModel(
      // NOTE: maxTokens is the FULL context window (prompt + response),
      // not a response limit. See kContextTokens.
      maxTokens: kContextTokens,
      // CPU backend: on 4 GB Android devices, GPU uses shared memory.
      // Gemma (~1.6 GB) on GPU + app heap routinely exhausts the 4 GB pool.
      // CPU keeps the model in pageable RAM where Android can manage pressure.
      preferredBackend: PreferredBackend.cpu,
    );

    _isLoaded = true;
  }

  /// Run inference and stream tokens as they are generated.
  ///
  /// [prompt] — the full formatted prompt string (includes full history).
  /// Yields token strings one at a time.
  ///
  /// A fresh session is created before each inference and the previous one is
  /// closed first. This frees the KV (key-value attention) cache between turns,
  /// keeping memory usage flat regardless of conversation length. The model
  /// weights in [_model] remain loaded — only the per-turn cache is recycled.
  Stream<String> chat({required String prompt}) async* {
    if (!_isLoaded || _model == null) {
      throw StateError('Model not loaded. Call loadModel() first.');
    }
    // Two concurrent calls would race on _session: the second would close the
    // session the first is still streaming from. The UI disables the send
    // button during generation, but that is a UI invariant, not a guarantee —
    // a scoped chat opened from a guide reader shares this same service.
    if (_isGenerating) {
      throw StateError('A response is already being generated.');
    }
    _isGenerating = true;

    try {
      // Null the reference FIRST so the old session's memory can be released
      // before the new session allocates. Without this, both sessions exist in
      // memory simultaneously (race condition -> OOM on the second+ turn).
      final prev = _session;
      _session = null;
      await prev?.close();

      _session = await _model!.createSession(temperature: 0.7, topK: 40);
      await _session!.addQueryChunk(Message(text: prompt));

      // handleError converts native inference failures into Dart exceptions
      // that the caller's try-catch can handle gracefully (show error in UI)
      // instead of crashing the app.
      yield* _session!.getResponseAsync().handleError((error) {
        throw StateError('Inference failed: $error');
      });
    } finally {
      // Runs on completion, error, AND on the consumer abandoning the stream
      // (e.g. navigating away mid-answer), so the service can never be left
      // permanently wedged in the generating state.
      _isGenerating = false;
    }
  }

  Future<void> disposeAsync() async {
    final session = _session;
    final model = _model;
    _session = null;
    _model = null;
    _isLoaded = false;
    _isGenerating = false;
    await session?.close();
    await model?.close();
  }
}
