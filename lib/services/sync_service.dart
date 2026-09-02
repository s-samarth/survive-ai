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
import '../models/doc_topic.dart';
import '../models/doc_chunk.dart';
import 'database_citations.dart';
import 'database_service.dart';
import 'index_loader_service.dart';
import 'chunker_service.dart';
import 'embedding_service.dart';

/// Where the content manifest lives.
///
/// Override at build time so a fork or a staging channel needs no code change:
///   flutter build apk --dart-define=SURVIVE_AI_MANIFEST_URL=https://.../manifest.json
///
/// The default points at this project's docs repo. If it is unreachable the app
/// is fully functional on its bundled corpus — sync is an enhancement, never a
/// dependency.
const kManifestUrl = String.fromEnvironment(
  'SURVIVE_AI_MANIFEST_URL',
  defaultValue:
      'https://raw.githubusercontent.com/samarthsaraswat/survive-ai-docs/main/manifest.json',
);

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

  /// Reads the prebuilt index; falls back to [_chunker] when absent.
  final IndexLoaderService _indexLoader;
  final EmbeddingService _embedder;

  SyncService(
    this._db,
    this._chunker,
    this._embedder, {
    IndexLoaderService indexLoader = const IndexLoaderService(),
  }) : _indexLoader = indexLoader;

  /// Version stamp for the bundled corpus. Bump this whenever the shipped
  /// Markdown changes so existing installs re-ingest on next launch instead of
  /// silently keeping stale chunks.
  static const bundledVersion = 'bundled-3.0-index';

  /// Seeds the database with the bundled India guides if they are not already
  /// ingested at [bundledVersion].
  ///
  /// Safe and cheap to call on every launch: topics already at the current
  /// version are skipped with a single indexed lookup, so the steady-state cost
  /// is one SELECT per topic. It **must** run on every launch — gating it
  /// behind the model download meant a sideloaded or pre-existing model left
  /// the corpus permanently empty.
  Future<void> seedFromAssets() async {
    // Prefer the index built offline by the Python indexer: it carries the
    // passage sizing the evals settled on and content-derived citation ids
    // that mean the same thing here, in the guide reader and in a report.
    // A build without the artifact still works through the runtime chunker.
    final index = await _indexLoader.load();

    for (final topic in DocTopic.values) {
      if (await _db.getDocVersion(topic.docId) == bundledVersion) continue;

      try {
        await _db.deleteChunksForDoc(topic.docId);
        await _db.deleteCitationsForDoc(topic.docId);

        final indexed = index?[topic.key];
        final List<DocChunk> chunks;
        if (indexed != null) {
          chunks = indexed.passages;
          await _db.insertChunks(chunks);
          await _db.insertCitations(indexed.citations);
        } else {
          final content = await rootBundle.loadString(topic.assetPath);
          chunks = _chunker.chunk(content, topic.docId, topic.key);
          await _db.insertChunks(chunks);
        }

        await _db.upsertDoc({
          'id': topic.docId,
          'filename': p.basename(topic.assetPath),
          'topic': topic.key,
          'version': bundledVersion,
          'checksum': '', // Bundled assets are trusted; no hash needed.
          'last_synced': DateTime.now().millisecondsSinceEpoch,
        });

        await _embedChunks(chunks);
      } catch (e) {
        debugPrint('Error seeding bundled guide ${topic.assetPath}: $e');
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
      return manifest.version != localVersion
          ? SyncStatus.updatesAvailable
          : SyncStatus.upToDate;
    } catch (_) {
      return SyncStatus.error;
    }
  }

  /// Full sync: fetch manifest, download changed docs, re-index, re-embed.
  ///
  /// [onProgress] — called with (downloaded, total) doc counts.
  Future<SyncResult> syncNow({
    void Function(int done, int total)? onProgress,
  }) async {
    if (!await isOnline()) {
      return SyncResult(status: SyncStatus.offline, updatedDocs: 0);
    }

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
      return SyncResult(
        status: SyncStatus.error,
        updatedDocs: 0,
        error: e.toString(),
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  /// Embed only the chunks that arrived without a vector.
  ///
  /// The bundled corpus ships pre-embedded, so in the ordinary case this does
  /// nothing at all — which is the point. Embedding 201 passages on a 6 GB
  /// phone at every launch would cost minutes and buy vectors identical to the
  /// ones already in the asset.
  ///
  /// What does reach here is a guide freshly downloaded from GitHub, chunked
  /// on the device and therefore absent from the shipped vector file. Leaving
  /// those unembedded would quietly exclude the newest content from the dense
  /// leg — present in keyword search, invisible to semantic search.
  ///
  /// When no embedder is available this is a no-op and the chunks keep NULL
  /// embeddings; retrieval falls back to its two lexical legs.
  Future<void> _embedChunks(List<DocChunk> chunks) async {
    if (!_embedder.isEnabled) return;
    final pending = chunks.where((c) => c.embedding == null).toList();
    if (pending.isEmpty) return;

    // Prepend heading to chunk body for richer semantic context
    final texts = pending
        .map((c) => c.headingPath.isNotEmpty ? '${c.headingPath}: ${c.body}' : c.body)
        .toList();

    final embeddings = await _embedder.embedBatch(texts);
    for (var i = 0; i < pending.length && i < embeddings.length; i++) {
      if (embeddings[i].isEmpty) continue;
      await _db.updateChunkEmbedding(pending[i].id, embeddings[i]);
    }
  }

  /// Fetch the model entry from the manifest, or null when offline or the
  /// manifest is unreachable. Callers fall back to their compiled-in defaults.
  /// The whole manifest, or null when offline or unreachable.
  Future<DocManifest?> fetchManifest() async {
    if (!await isOnline()) return null;
    try {
      return await _fetchManifest();
    } catch (e) {
      debugPrint('Could not fetch the manifest: $e');
      return null;
    }
  }

  Future<ModelInfo?> fetchModelInfo() async {
    if (!await isOnline()) return null;
    try {
      return (await _fetchManifest()).model;
    } catch (e) {
      debugPrint('Could not fetch model info from manifest: $e');
      return null;
    }
  }

  Future<DocManifest> _fetchManifest() async {
    final response = await http.get(Uri.parse(kManifestUrl));
    if (response.statusCode != 200) {
      throw Exception('Failed to fetch manifest: ${response.statusCode}');
    }
    return DocManifest.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  Future<String> _downloadDoc(String url) async {
    final response = await http.get(Uri.parse(url));
    if (response.statusCode != 200) {
      throw Exception('Failed to download doc: $url');
    }
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

  const SyncResult({
    required this.status,
    required this.updatedDocs,
    this.error,
  });
}
