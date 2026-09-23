import 'package:flutter/foundation.dart';

import '../../models/doc_manifest.dart';
import '../download_service.dart';
import 'onnx_embedder.dart';

/// Fetches the query encoder: an ONNX graph and the weight sidecar beside it.
///
/// Two files, downloaded as a set. ONNX Runtime resolves external initializers
/// by the filename recorded inside the graph, so the sidecar has to land in the
/// same directory under exactly that name — and a graph without its weights
/// opens far enough to look healthy and then fails at the first inference.
/// Treating them as one unit is what keeps that state from existing.
///
/// External weights are the point rather than an inconvenience: ONNX Runtime
/// memory-maps them, so the 175 MB is file-backed and the OS can evict it when
/// Gemma needs the RAM. Inlining them into a single self-contained graph would
/// be simpler to ship and would hold the same bytes as anonymous memory for the
/// life of the process, on a device with 6 GB.
class EncoderDownload {
  const EncoderDownload({DownloadService? downloads})
    : _downloads = downloads ?? const DownloadService();

  final DownloadService _downloads;

  /// Where both files live, alongside the generator.
  static const String subfolder = 'models';

  /// Used when the manifest carries no `embedder` entry, so a build can fetch
  /// the encoder before any manifest has been published. The manifest wins
  /// whenever it has one, which is what lets the encoder be swapped without
  /// shipping an APK.
  ///
  /// Pinned to a commit with exact sizes and hashes, like the generator: the
  /// shipped passage vectors were made by this exact graph, and a different
  /// one would score queries against them without any error.
  static const List<ModelInfo> fallback = [
    ModelInfo(
      name: OnnxEmbeddingService.graphFile,
      url: '$_repo/onnx/model_q4f16.onnx',
      sizeBytes: 705221,
      sha256:
          '4df4a2a44253865800b8882a497badf67c2707a487267460813f78da339c753f',
    ),
    ModelInfo(
      name: OnnxEmbeddingService.weightsFile,
      url: '$_repo/onnx/model_q4f16.onnx_data',
      sizeBytes: 175410176,
      sha256:
          'c9cc456a345e6aa9bc5fb75b54c10b3e0edbb4f80708f749dc4c45dbed5b6edf',
    ),
  ];

  static const String _repo =
      'https://huggingface.co/onnx-community/embeddinggemma-300m-ONNX/'
      'resolve/5090578d9565bb06545b4552f76e6bc2c93e4a66';

  /// Total bytes to fetch, for a size shown before the user commits.
  static int totalBytes(List<ModelInfo> files) =>
      files.fold(0, (sum, f) => sum + f.sizeBytes);

  /// Download every file, reporting combined progress across the set.
  ///
  /// [onProgress] receives `0.0`–`1.0` over the whole download rather than per
  /// file, because a bar that fills, resets and fills again reads as a stall.
  ///
  /// Returns true when every file arrived. A partial set leaves whatever
  /// completed on disk: the downloads are resumable, and discarding 170 MB
  /// because the last few bytes failed is the wrong outcome on a connection
  /// that drops.
  Future<bool> fetch(
    List<ModelInfo> files, {
    void Function(double progress)? onProgress,
  }) async {
    if (files.isEmpty) return false;
    final total = totalBytes(files);
    var completed = 0;

    for (final file in files) {
      try {
        await _downloads.download(
          url: file.url,
          filename: file.name,
          subfolder: subfolder,
          expectedBytes: file.sizeBytes,
          expectedSha256: file.sha256,
          onProgress: (downloaded, _) {
            if (total > 0) {
              onProgress?.call(((completed + downloaded) / total).clamp(0, 1));
            }
          },
        );
        completed += file.sizeBytes;
      } catch (error) {
        debugPrint('Query encoder download failed for ${file.name}: $error');
        return false;
      }
    }
    onProgress?.call(1);
    return true;
  }
}
