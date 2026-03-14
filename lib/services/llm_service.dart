import 'dart:async';
import 'package:llama_cpp_dart/llama_cpp_dart.dart';

/// Wraps llama_cpp_dart to provide model loading and token-streaming chat.
///
/// Uses [LlamaParent] (isolate-based) so inference runs on a background
/// isolate and never blocks the UI thread.
class LlmService {
  LlamaParent? _parent;
  bool _isLoaded = false;

  bool get isLoaded => _isLoaded;

  /// Load the GGUF model from [modelPath] into memory.
  ///
  /// Should be called once on first launch after the model file is downloaded.
  /// Runs model loading in a background isolate via [LlamaParent].
  Future<void> loadModel(String modelPath) async {
    if (_isLoaded) return;

    final loadCommand = LlamaLoad(
      path: modelPath,
      modelParams: ModelParams()..nGpuLayers = 0, // CPU-only
      contextParams: ContextParams()
        ..nCtx = 4096    // context window: comfortable for RAG + history
        ..nThreads = 4   // safe default for mid-range ARM SoCs
        ..nPredict = 512, // max tokens to generate per turn
      samplingParams: SamplerParams()
        ..temp = 0.7
        ..topK = 40
        ..topP = 0.95,
    );

    _parent = LlamaParent(loadCommand, GemmaFormat());
    await _parent!.init();
    _isLoaded = true;
  }

  /// Run inference and stream tokens as they are generated.
  ///
  /// [prompt] — the full formatted prompt string (built by [PromptBuilder]).
  /// Yields token strings one at a time; caller concatenates into full response.
  Stream<String> chat({required String prompt}) async* {
    if (!_isLoaded || _parent == null) {
      throw StateError('Model not loaded. Call loadModel() first.');
    }

    final controller = StreamController<String>();

    final sub = _parent!.stream.listen(
      (token) => controller.add(token),
      onDone: () => controller.close(),
      onError: (Object e) {
        controller.addError(e);
        controller.close();
      },
    );

    final promptId = await _parent!.sendPrompt(prompt);
    yield* controller.stream;

    await _parent!.waitForCompletion(promptId);
    await sub.cancel();
  }

  Future<void> disposeAsync() async {
    await _parent?.dispose();
    _parent = null;
    _isLoaded = false;
  }
}
