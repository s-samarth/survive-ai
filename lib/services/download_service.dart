import 'dart:io';
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

    // Rename .part to final file
    if (await file.exists()) await file.delete();
    await tempFile.rename(filePath);

    return filePath;
  }

  /// Check if a file already exists at the expected location.
  /// Checks both getApplicationDocumentsDirectory and getExternalStorageDirectory (for sideloaded files via adb).
  Future<String?> getExistingFile(String filename, String subfolder) async {
    // 1. Check internal documents directory
    final appDir = await getApplicationDocumentsDirectory();
    final internalPath = p.join(appDir.path, subfolder, filename);
    if (await File(internalPath).exists()) return internalPath;

    // 2. Check external storage directory (Android only - /sdcard/Android/data/...)
    if (Platform.isAndroid) {
      final extDir = await getExternalStorageDirectory();
      if (extDir != null) {
        final externalPath = p.join(extDir.path, subfolder, filename);
        if (await File(externalPath).exists()) return externalPath;
      }
    }

    return null;
  }

  /// Find the model file in any known location.
  ///
  /// Checks (in order):
  /// 1. Our models/ subfolder — written by [download]
  /// 2. Root of app documents directory — written by flutter_gemma's fromNetwork()
  /// 3. External storage — sideloaded via ADB
  ///
  /// Returns the absolute path if found, null otherwise.
  Future<String?> findModelFile(String filename) async {
    // 1. Our managed subfolder
    final managed = await getExistingFile(filename, 'models');
    if (managed != null) return managed;

    // 2. flutter_gemma's network-download location (root of app docs)
    final appDir = await getApplicationDocumentsDirectory();
    final rootPath = p.join(appDir.path, filename);
    if (await File(rootPath).exists()) return rootPath;

    return null;
  }

  Future<void> deleteFile(String filename, String subfolder) async {
    final docsDir = await getApplicationDocumentsDirectory();
    final file = File(p.join(docsDir.path, subfolder, filename));
    if (await file.exists()) {
      await file.delete();
    }

    // Also check external storage
    if (Platform.isAndroid) {
      final extDir = await getExternalStorageDirectory();
      if (extDir != null) {
        final extFile = File(p.join(extDir.path, subfolder, filename));
        if (await extFile.exists()) {
          await extFile.delete();
        }
      }
    }
  }
}
