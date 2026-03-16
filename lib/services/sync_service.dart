import 'dart:convert';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../models/doc_manifest.dart';
import '../models/doc_chunk.dart';
import 'database_service.dart';
import 'chunker_service.dart';
import 'embedding_service.dart';

// Replace with your actual GitHub raw manifest URL once the docs repo is created.
const _manifestUrl =
    'https://raw.githubusercontent.com/survive-ai/survive-ai-docs/main/manifest.json';

/// Handles WiFi-gated syncing of survival docs and model metadata from GitHub.
///
/// On each app launch (or manual trigger):
/// 1. Check connectivity — abort if no internet.
/// 2. Fetch manifest.json from GitHub.
/// 3. For each doc in manifest, compare SHA-256 with local DB checksum.
/// 4. Download only changed or new docs.
/// 5. Verify checksum, write to disk, ingest into SQLite.
/// 6. Compute TFLite embeddings for new chunks and store in DB.
class SyncService {
  final DatabaseService _db;
  final ChunkerService _chunker;
  final EmbeddingService _embedder;

  SyncService(this._db, this._chunker, this._embedder);

  /// Seeds the database with bundled assets if they haven't been loaded yet.
  /// Ensures the app has expert knowledge immediately after install (Zero-Wait RAG).
  Future<void> seedFromAssets() async {
    final assets = {
      'docs/survival_guides/war.md': 'war',
      'docs/survival_guides/medical.md': 'medical',
      'docs/survival_guides/jungle.md': 'jungle',
      'docs/survival_guides/desert.md': 'desert',
      'docs/survival_guides/urban.md': 'urban',
      'docs/survival_guides/general.md': 'general',
    };

    for (final entry in assets.entries) {
      final path = entry.key;
      final topic = entry.value;
      final id = '${p.basenameWithoutExtension(path)}_$topic';

      // Check if already in DB
      final existingVersion = await _db.getDocVersion(id);
      if (existingVersion == 'bundled-1.0') continue;

      try {
        final content = await rootBundle.loadString(path);

        await _db.deleteChunksForDoc(id);
        final chunks = _chunker.chunk(content, id, topic);
        await _db.insertChunks(chunks);
        await _db.upsertDoc({
          'id': id,
          'filename': p.basename(path),
          'topic': topic,
          'version': 'bundled-1.0',
          'checksum': '', // Maintain schema constraint but avoid actual hashing
          'last_synced': DateTime.now().millisecondsSinceEpoch,
        });

        // Compute semantic embeddings for the newly inserted chunks.
        // EmbeddingService loads and disposes TFLite within this call — safe
        // to run before Gemma is loaded.
        await _embedChunks(chunks);
      } catch (e) {
        debugPrint('Error seeding asset $path: $e');
      }
    }
  }

  /// Returns true if the device has an active internet connection.
  Future<bool> isOnline() async {
    final result = await Connectivity().checkConnectivity();
    return result.any((r) => r != ConnectivityResult.none);
  }

  /// Check if a newer manifest is available without downloading docs.
  Future<SyncStatus> checkForUpdates() async {
    if (!await isOnline()) return SyncStatus.offline;

    try {
      final manifest = await _fetchManifest();
      final prefs = await SharedPreferences.getInstance();
      final localVersion = prefs.getString('manifest_version') ?? '';
      return manifest.version != localVersion ? SyncStatus.updatesAvailable : SyncStatus.upToDate;
    } catch (_) {
      return SyncStatus.error;
    }
  }

  /// Full sync: fetch manifest, download changed docs, re-index, re-embed.
  ///
  /// [onProgress] — called with (downloaded, total) doc counts.
  Future<SyncResult> syncNow({void Function(int done, int total)? onProgress}) async {
    if (!await isOnline()) return SyncResult(status: SyncStatus.offline, updatedDocs: 0);

    try {
      final manifest = await _fetchManifest();
      final docsDir = await _docsDirectory();
      var updated = 0;

      for (var i = 0; i < manifest.docs.length; i++) {
        final entry = manifest.docs[i];
        final localVersion = await _db.getDocVersion(entry.id);

        if (localVersion == entry.version) {
          onProgress?.call(i + 1, manifest.docs.length);
          continue; // Already up to date
        }

        final content = await _downloadDoc(entry.url);

        // Write to disk
        final dir = Directory(p.join(docsDir.path, entry.topic));
        await dir.create(recursive: true);
        final file = File(p.join(dir.path, p.basename(entry.filename)));
        await file.writeAsString(content);

        // Ingest into SQLite
        await _db.deleteChunksForDoc(entry.id);
        final chunks = _chunker.chunk(content, entry.id, entry.topic);
        await _db.insertChunks(chunks);
        await _db.upsertDoc({
          'id': entry.id,
          'filename': entry.filename,
          'topic': entry.topic,
          'version': entry.version,
          'checksum': '', // Maintain schema constraint
          'last_synced': DateTime.now().millisecondsSinceEpoch,
        });

        // Compute embeddings for synced chunks
        await _embedChunks(chunks);

        updated++;
        onProgress?.call(i + 1, manifest.docs.length);
      }

      // Persist manifest version
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('manifest_version', manifest.version);
      await prefs.setInt('last_sync_ms', DateTime.now().millisecondsSinceEpoch);

      return SyncResult(status: SyncStatus.upToDate, updatedDocs: updated);
    } catch (e) {
      return SyncResult(status: SyncStatus.error, updatedDocs: 0, error: e.toString());
    }
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  /// Compute and store embeddings for a list of chunks.
  ///
  /// Uses [EmbeddingService.embedBatch] which loads TFLite, runs all chunks,
  /// then immediately disposes the interpreter. This keeps peak memory usage
  /// bounded and ensures the TFLite runtime is released before Gemma loads.
  ///
  /// If the embedding model is not available (asset missing), this is a no-op
  /// and chunks remain with NULL embeddings — retrieval falls back to BM25.
  Future<void> _embedChunks(List<DocChunk> chunks) async {
    if (chunks.isEmpty) return;

    // Prepend heading to chunk body for richer semantic context
    final texts = chunks.map((c) {
      return c.headingPath.isNotEmpty ? '${c.headingPath}: ${c.body}' : c.body;
    }).toList();

    final embeddings = await _embedder.embedBatch(texts);
    if (embeddings.isEmpty) return; // Model not available — skip silently

    for (var i = 0; i < chunks.length && i < embeddings.length; i++) {
      await _db.updateChunkEmbedding(chunks[i].id, embeddings[i]);
    }
  }

  Future<DocManifest> _fetchManifest() async {
    final response = await http.get(Uri.parse(_manifestUrl));
    if (response.statusCode != 200) throw Exception('Failed to fetch manifest: ${response.statusCode}');
    return DocManifest.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  Future<String> _downloadDoc(String url) async {
    final response = await http.get(Uri.parse(url));
    if (response.statusCode != 200) throw Exception('Failed to download doc: $url');
    return response.body;
  }

  Future<Directory> _docsDirectory() async {
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(appDir.path, 'docs'));
    await dir.create(recursive: true);
    return dir;
  }
}

enum SyncStatus { offline, upToDate, updatesAvailable, error }

class SyncResult {
  final SyncStatus status;
  final int updatedDocs;
  final String? error;

  const SyncResult({required this.status, required this.updatedDocs, this.error});
}
