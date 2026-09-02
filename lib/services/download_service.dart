import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

/// Thrown when a completed download does not match its expected SHA-256.
class ChecksumMismatchException implements Exception {
  final String expected;
  final String actual;
  const ChecksumMismatchException(this.expected, this.actual);

  @override
  String toString() =>
      'Downloaded file is corrupt (expected sha256 $expected, got $actual)';
}

/// Resumable file downloads with SHA-256 verification.
///
/// Used for the ~1.3 GB model and for individual doc files. On a 2G/3G
/// connection in a village, a 1.3 GB download will be interrupted many times,
/// so resume is not a nicety — it is the only way the download ever completes.
class DownloadService {
  const DownloadService();

  /// Download [url] into `<app documents>/<subfolder>/<filename>`.
  ///
  /// Resumes from a previous partial download when the sidecar metadata proves
  /// the partial came from the same URL and the same expected content.
  ///
  /// [expectedSha256] — when given, the finished file is hashed and the
  /// download is discarded if it does not match. Without this, a truncated or
  /// corrupted 1.3 GB body was renamed into place and only failed later at
  /// model load, which the user saw as an unexplained crash loop.
  Future<String> download({
    required String url,
    required String filename,
    required String subfolder,
    String? expectedSha256,
    int? expectedBytes,
    void Function(int downloaded, int total)? onProgress,
  }) async {
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(appDir.path, subfolder));
    await dir.create(recursive: true);

    final filePath = p.join(dir.path, filename);
    final tempFile = File('$filePath.part');
    final metaFile = File('$filePath.part.json');

    final resumeKey = jsonEncode({
      'url': url,
      'bytes': expectedBytes,
      'sha256': expectedSha256,
    });

    // Only resume when the partial provably belongs to this exact download.
    // Blindly appending to whatever .part happened to be on disk produced a
    // file that was the right size and complete garbage.
    var existingBytes = 0;
    if (await tempFile.exists()) {
      final sameSource =
          await metaFile.exists() && await metaFile.readAsString() == resumeKey;
      if (sameSource) {
        existingBytes = await tempFile.length();
      } else {
        await tempFile.delete();
      }
    }
    await metaFile.writeAsString(resumeKey);

    final request = http.Request('GET', Uri.parse(url));
    if (existingBytes > 0) request.headers['Range'] = 'bytes=$existingBytes-';

    final client = http.Client();
    try {
      final response = await client.send(request);

      if (response.statusCode == 200 && existingBytes > 0) {
        // Server ignored the Range header — start over.
        existingBytes = 0;
        if (await tempFile.exists()) await tempFile.delete();
      } else if (response.statusCode == 206) {
        // Trust the resume only if the server confirms the offset it is
        // sending from. A 206 starting at a different byte silently corrupts.
        final range = response.headers['content-range'];
        if (!_rangeStartsAt(range, existingBytes)) {
          throw Exception(
            'Server returned an unexpected byte range: $range '
            '(expected to resume at $existingBytes)',
          );
        }
      } else if (response.statusCode != 200) {
        throw Exception('Download failed: HTTP ${response.statusCode}');
      }

      final total =
          expectedBytes ?? (existingBytes + (response.contentLength ?? 0));

      final sink = tempFile.openWrite(
        mode: existingBytes > 0 ? FileMode.append : FileMode.write,
      );
      var downloaded = existingBytes;
      try {
        await for (final chunk in response.stream) {
          sink.add(chunk);
          downloaded += chunk.length;
          onProgress?.call(downloaded, total);
        }
      } finally {
        await sink.flush();
        await sink.close();
      }

      // Size check first — it is free and catches most truncations.
      final actualBytes = await tempFile.length();
      if (expectedBytes != null && actualBytes != expectedBytes) {
        await tempFile.delete();
        await metaFile.delete();
        throw Exception(
          'Download incomplete: got $actualBytes of $expectedBytes bytes',
        );
      }

      if (expectedSha256 != null) {
        final actual = await sha256OfFile(tempFile);
        if (actual != expectedSha256.toLowerCase()) {
          await tempFile.delete();
          await metaFile.delete();
          throw ChecksumMismatchException(expectedSha256, actual);
        }
      }

      final file = File(filePath);
      if (await file.exists()) await file.delete();
      await tempFile.rename(filePath);
      if (await metaFile.exists()) await metaFile.delete();

      return filePath;
    } finally {
      client.close();
    }
  }

  /// Streaming SHA-256 so a 1.3 GB file is never held in memory.
  static Future<String> sha256OfFile(File file) async {
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString();
  }

  static bool _rangeStartsAt(String? contentRange, int offset) {
    if (contentRange == null) return false;
    final match = RegExp(r'bytes\s+(\d+)-').firstMatch(contentRange);
    return match != null && int.tryParse(match.group(1)!) == offset;
  }

  /// Every directory a model file may legitimately live in.
  ///
  /// [findModelFile] and [deleteFile] must agree on this list — when they did
  /// not, "Repair" deleted a copy that was not the one being loaded and the
  /// app looped through the same failing model forever.
  Future<List<String>> modelSearchPaths(String filename) async {
    final appDir = await getApplicationDocumentsDirectory();
    final paths = <String>[
      p.join(appDir.path, 'models', filename), // written by [download]
      p.join(appDir.path, filename), // flutter_gemma's own download location
    ];
    if (Platform.isAndroid) {
      final extDir = await getExternalStorageDirectory();
      if (extDir != null) {
        paths.add(p.join(extDir.path, 'models', filename)); // adb sideload
        paths.add(p.join(extDir.path, filename));
      }
    }
    return paths;
  }

  /// Absolute path of [filename] in the first location it is found, else null.
  Future<String?> findModelFile(String filename) async {
    for (final path in await modelSearchPaths(filename)) {
      if (await File(path).exists()) return path;
    }
    return null;
  }

  /// Delete [filename] from every known location, plus any partial download.
  ///
  /// Returns the number of files removed.
  Future<int> deleteFile(String filename) async {
    var removed = 0;
    for (final path in await modelSearchPaths(filename)) {
      for (final candidate in [
        File(path),
        File('$path.part'),
        File('$path.part.json'),
      ]) {
        try {
          if (await candidate.exists()) {
            await candidate.delete();
            removed++;
          }
        } catch (e) {
          debugPrint('Could not delete ${candidate.path}: $e');
        }
      }
    }
    return removed;
  }
}
