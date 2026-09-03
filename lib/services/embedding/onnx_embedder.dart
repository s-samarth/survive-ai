import 'package:flutter/foundation.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

import '../embedding_service.dart';
import 'gemma_tokenizer.dart';

/// EmbeddingGemma-300m running under ONNX Runtime, encoding the query only.
///
/// Documents never reach this class in the normal path: the corpus is embedded
/// offline and ships as `assets/index/passages.f32`. Only the query has to be
/// encoded on the device, and that is a single forward pass over roughly ten
/// tokens. That asymmetry is the entire reason a 300M-parameter encoder fits
/// beside a 2B generator inside a 6 GB budget.
///
/// The graph is the community `q4f16` export, 175 MB against 1.2 GB for the
/// float one, and it carries its weights in a sidecar `.onnx_data` file that
/// ONNX Runtime memory-maps — so the pages are file-backed and the OS can
/// reclaim them when Gemma needs the RAM, rather than the encoder holding
/// 175 MB of anonymous memory for the life of the process.
///
/// Quantization was measured, not assumed. Scored end to end on the retrieval
/// golden set with the graph on both sides — queries and documents — it
/// reaches Recall@5 89.7%, Recall@20 98.2%, MRR 75.9%, against 89.7 / 97.9 /
/// 77.1 for the float model in PyTorch. Neutral on the headline metric, a
/// little better in the tail, a little worse in the ordering.
///
/// "On both sides" is the load-bearing part. The first run of this comparison
/// reported 90.0% and was wrong: the lab's vector cache was keyed by model and
/// dimension but not by backend, so a run asked for ONNX quietly reused
/// PyTorch document vectors and scored them against ONNX queries — a hybrid no
/// device can run. A quantised export is a different model, not a packaging
/// detail, and it has to be measured as one.
///
/// Pooling and both projection layers are baked into the graph, which exposes
/// a `sentence_embedding` output directly. Reading `last_hidden_state` and
/// mean-pooling it by hand — the obvious thing to do, and what the lab backend
/// did for every earlier model — silently skips the projection head and yields
/// vectors from a different space than the shipped ones.
class OnnxEmbeddingService extends EmbeddingService {
  OnnxEmbeddingService._(
    this._session,
    this._tokenizer, {
    required this.queryPrefix,
    required this.documentPrefix,
    required int dimensions,
  }) : _dimensions = dimensions;

  /// The graph output holding the pooled, projected, L2-normalised vector.
  static const String outputName = 'sentence_embedding';

  /// Filenames the downloader writes; the sidecar must sit beside the graph
  /// under exactly this name or ONNX Runtime cannot resolve the weights.
  static const String graphFile = 'embeddinggemma-300m-q4f16.onnx';
  static const String weightsFile = '${graphFile}_data';

  final OrtSession _session;
  final GemmaTokenizer _tokenizer;
  final int _dimensions;

  /// EmbeddingGemma is trained with asymmetric task prefixes and loses real
  /// accuracy without them, so they come from the same manifest that
  /// described the shipped vectors rather than being retyped here.
  final String queryPrefix;
  final String documentPrefix;

  @override
  bool get isEnabled => true;

  @override
  int get dimensions => _dimensions;

  /// Open a session over an already-downloaded graph.
  ///
  /// Returns null when the model is absent, which is the ordinary state before
  /// the encoder has been fetched — the app runs on its lexical legs until
  /// then rather than refusing to start.
  static Future<OnnxEmbeddingService?> tryLoad({
    required String modelPath,
    required GemmaTokenizer tokenizer,
    required String queryPrefix,
    required String documentPrefix,
    required int dimensions,
    OnnxRuntime? runtime,
  }) async {
    try {
      final session = await (runtime ?? OnnxRuntime()).createSession(modelPath);
      if (!session.outputNames.contains(outputName)) {
        // A graph without the projection head would produce vectors that are
        // not comparable with the shipped ones. Refusing beats degrading.
        await session.close();
        throw StateError(
          'graph exposes ${session.outputNames}, not "$outputName"',
        );
      }
      return OnnxEmbeddingService._(
        session,
        tokenizer,
        queryPrefix: queryPrefix,
        documentPrefix: documentPrefix,
        dimensions: dimensions,
      );
    } catch (error) {
      debugPrint('Embedding model unavailable, dense leg disabled: $error');
      return null;
    }
  }

  @override
  Future<Float32List> embedQuery(String text) async =>
      _encode(queryPrefix + text);

  @override
  Future<List<Float32List>> embedBatch(List<String> texts) async {
    // Sequential rather than batched on purpose. Batching pads every row to
    // the longest, and a batch of survival paragraphs is ragged enough that
    // padding costs more than the per-call overhead it saves — on a device
    // where the peak allocation, not the throughput, is what breaks.
    final out = <Float32List>[];
    for (final text in texts) {
      out.add(await _encode(documentPrefix + text));
    }
    return out;
  }

  /// One forward pass. Returns an empty vector on failure so a retrieval leg
  /// degrades instead of taking the turn down with it.
  Future<Float32List> _encode(String text) async {
    final ids = _tokenizer.encode(text);
    final shape = [1, ids.length];
    OrtValue? inputIds;
    OrtValue? attentionMask;
    try {
      inputIds = await OrtValue.fromList(Int64List.fromList(ids), shape);
      attentionMask = await OrtValue.fromList(
        Int64List(ids.length)..fillRange(0, ids.length, 1),
        shape,
      );
      final outputs = await _session.run({
        'input_ids': inputIds,
        'attention_mask': attentionMask,
      });
      final vector = await outputs[outputName]?.asFlattenedList();
      if (vector == null) return Float32List(0);
      return Float32List.fromList(
        vector.cast<num>().map((v) => v.toDouble()).toList(),
      );
    } catch (error) {
      debugPrint('Embedding failed for a ${ids.length}-token input: $error');
      return Float32List(0);
    } finally {
      await inputIds?.dispose();
      await attentionMask?.dispose();
    }
  }

  /// Release the session and its mapped weights.
  Future<void> dispose() => _session.close();
}
