import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

/// Handles resumable file downloads with SHA-256 verification.
///
/// Used for both the GGUF model (~500MB) and individual doc files.
/// Supports HTTP Range headers for resuming interrupted downloads.
class DownloadService {
  /// Download a file from [url] to the app's files directory.
  ///
  /// [filename] — the local filename to save as (e.g. 'gemma-3-1b-it-Q4_K_M.gguf').
  /// [subfolder] — subdirectory under app files (e.g. 'models').
  /// [expectedSha256] — if provided, verifies checksum after download.
  /// [expectedBytes] — total expected file size (for progress calculation).
  /// [onProgress] — called with (bytesDownloaded, totalBytes).
  ///
  /// Returns the full path to the downloaded file.
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
    final file = File(filePath);
    final tempPath = '$filePath.part';
    final tempFile = File(tempPath);

    // Check existing bytes for resume
    int existingBytes = 0;
    if (await tempFile.exists()) {
      existingBytes = await tempFile.length();
    }

    final totalBytes = expectedBytes ?? 0;

    // Build request with Range header for resume
    final request = http.Request('GET', Uri.parse(url));
    if (existingBytes > 0) {
      request.headers['Range'] = 'bytes=$existingBytes-';
    }

    final response = await http.Client().send(request);

    // If server doesn't support Range, start over
    if (response.statusCode == 200 && existingBytes > 0) {
      existingBytes = 0;
      if (await tempFile.exists()) await tempFile.delete();
    }

    if (response.statusCode != 200 && response.statusCode != 206) {
      throw Exception('Download failed: HTTP ${response.statusCode}');
    }

    final contentLength = response.contentLength ?? 0;
    final total = existingBytes + contentLength;
    final effectiveTotal = totalBytes > 0 ? totalBytes : total;

    final sink = tempFile.openWrite(mode: existingBytes > 0 ? FileMode.append : FileMode.write);
    int downloaded = existingBytes;

    try {
      await for (final chunk in response.stream) {
        sink.add(chunk);
        downloaded += chunk.length;
        onProgress?.call(downloaded, effectiveTotal);
      }
    } finally {
      await sink.flush();
      await sink.close();
    }

    // Verify checksum
    if (expectedSha256 != null) {
      final hash = await _computeSha256(tempFile);
      if (hash != expectedSha256) {
        await tempFile.delete();
        throw Exception('Checksum mismatch: expected $expectedSha256, got $hash');
      }
    }

    // Rename .part to final file
    if (await file.exists()) await file.delete();
    await tempFile.rename(filePath);

    return filePath;
  }

  /// Check if a file already exists at the expected location.
  Future<String?> getExistingFile(String filename, String subfolder) async {
    final appDir = await getApplicationDocumentsDirectory();
    final filePath = p.join(appDir.path, subfolder, filename);
    final file = File(filePath);
    if (await file.exists()) return filePath;
    return null;
  }

  /// Verify an existing file's SHA-256 checksum.
  Future<bool> verifyChecksum(String filePath, String expectedSha256) async {
    final file = File(filePath);
    if (!await file.exists()) return false;
    final hash = await _computeSha256(file);
    return hash == expectedSha256;
  }

  Future<String> _computeSha256(File file) async {
    final stream = file.openRead();
    final digest = await sha256.bind(stream).first;
    return digest.toString();
  }
}
