import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../embedding_service.dart';
import 'gemma_tokenizer.dart';
import 'onnx_embedder.dart';
import 'vector_index.dart';

/// Assembles the dense retrieval leg from its three artifacts.
///
/// They are only meaningful together: the vector file places every passage in
/// EmbeddingGemma's space, the ONNX graph puts a query into that same space,
/// and the packed tokenizer decides what the graph is actually shown. A
/// mismatch between any two produces vectors that are individually plausible
/// and jointly meaningless, with no error and no symptom beyond retrieval
/// being quietly worse — so this refuses to assemble a partial set.
///
/// The graph is the only piece that is downloaded rather than bundled: at
/// 175 MB it does not belong in an APK, and it rides the same manifest and
/// resumable-download path as the generator.
class EmbedderBootstrap {
  const EmbedderBootstrap({
    Future<ByteData> Function(String key)? readBinary,
    Future<String> Function(String key)? readString,
    Future<Directory> Function()? documentsDirectory,
  }) : _readBinary = readBinary,
       _readString = readString,
       _documentsDirectory = documentsDirectory;

  final Future<ByteData> Function(String key)? _readBinary;
  final Future<String> Function(String key)? _readString;
  final Future<Directory> Function()? _documentsDirectory;

  static const String tokenizerAsset = 'assets/index/tokenizer.bin';
  static const String modelSubfolder = 'models';

  /// Where the downloader must place the graph and its weight sidecar.
  Future<String> graphPath() async {
    final dir = _documentsDirectory ?? getApplicationDocumentsDirectory;
    return p.join(
      (await dir()).path,
      modelSubfolder,
      OnnxEmbeddingService.graphFile,
    );
  }

  /// True once both halves of the encoder are on disk.
  ///
  /// The weights live in a sidecar that ONNX Runtime memory-maps by name; a
  /// graph without it loads far enough to look present and then fails at the
  /// first inference, which is a worse failure than not being there at all.
  Future<bool> isDownloaded() async {
    final graph = await graphPath();
    return File(graph).exists().then(
      (hasGraph) async =>
          hasGraph &&
          await File(
            p.join(p.dirname(graph), OnnxEmbeddingService.weightsFile),
          ).exists(),
    );
  }

  /// Load the shipped passage vectors, or null when they are absent.
  Future<VectorIndex?> loadVectors() => VectorIndex.load(
    readBinary: _readBinary,
    readString: _readString,
  );

  /// Build the encoder, or return a disabled [EmbeddingService].
  ///
  /// Never throws and never returns null: a device without the encoder answers
  /// on its two lexical legs, which is a degradation the app is designed for.
  /// Failing to start because a 175 MB optional download is missing would be a
  /// far worse outcome than slightly weaker retrieval.
  Future<EmbeddingService> load(VectorIndex? vectors) async {
    if (vectors == null) return EmbeddingService();
    try {
      if (!await isDownloaded()) {
        debugPrint('Query encoder not downloaded yet; dense leg disabled.');
        return EmbeddingService();
      }
      final read = _readBinary ?? rootBundle.load;
      final tokenizer = GemmaTokenizer.parse(await read(tokenizerAsset));

      final embedder = await OnnxEmbeddingService.tryLoad(
        modelPath: await graphPath(),
        tokenizer: tokenizer,
        queryPrefix: vectors.queryPrefix,
        // The document prefix is fixed by the model, and only reaches guides
        // synced after the shipped vectors were built.
        documentPrefix: 'title: none | text: ',
        dimensions: vectors.dimensions,
      );
      return embedder ?? EmbeddingService();
    } catch (error) {
      debugPrint('Could not assemble the query encoder: $error');
      return EmbeddingService();
    }
  }
}
