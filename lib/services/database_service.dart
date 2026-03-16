import 'dart:typed_data';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../models/doc_chunk.dart';

/// Owns the SQLite database: schema creation, migrations, and all CRUD.
///
/// Tables:
/// - chunks: raw chunk metadata + body
/// - chunks_fts: FTS5 virtual table for BM25 keyword search
/// - docs: document registry with sync state
class DatabaseService {
  static const _dbName = 'survive_ai.db';
  static const _dbVersion = 1;

  Database? _db;

  Future<Database> get db async {
    _db ??= await _open();
    return _db!;
  }

  Future<Database> _open() async {
    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, _dbName);
    return openDatabase(
      path,
      version: _dbVersion,
      onCreate: _onCreate,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE docs (
        id TEXT PRIMARY KEY,
        filename TEXT NOT NULL,
        topic TEXT NOT NULL,
        version TEXT NOT NULL,
        checksum TEXT NOT NULL,
        last_synced INTEGER
      )
    ''');

    await db.execute('''
      CREATE TABLE chunks (
        id TEXT PRIMARY KEY,
        doc_id TEXT NOT NULL REFERENCES docs(id) ON DELETE CASCADE,
        topic TEXT NOT NULL,
        heading_path TEXT NOT NULL DEFAULT '',
        body TEXT NOT NULL,
        chunk_index INTEGER NOT NULL,
        embedding BLOB
      )
    ''');

    // FTS5 virtual table for BM25 full-text search.
    // porter stemmer normalizes: "running" → "run", "wounds" → "wound"
    await db.execute('''
      CREATE VIRTUAL TABLE chunks_fts USING fts5(
        chunk_id UNINDEXED,
        topic,
        heading_path,
        body,
        tokenize = 'porter ascii'
      )
    ''');

  }

  // ── Chunks ──────────────────────────────────────────────────────────────────

  Future<void> insertChunks(List<DocChunk> chunks) async {
    final database = await db;
    final batch = database.batch();
    for (final chunk in chunks) {
      batch.insert('chunks', chunk.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
      batch.insert('chunks_fts', {
        'chunk_id': chunk.id,
        'topic': chunk.topic,
        'heading_path': chunk.headingPath,
        'body': chunk.body,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  Future<void> deleteChunksForDoc(String docId) async {
    final database = await db;
    final chunkIds = await database.query(
      'chunks',
      columns: ['id'],
      where: 'doc_id = ?',
      whereArgs: [docId],
    );
    final ids = chunkIds.map((r) => r['id'] as String).toList();
    if (ids.isEmpty) return;

    final batch = database.batch();
    batch.delete('chunks', where: 'doc_id = ?', whereArgs: [docId]);
    for (final id in ids) {
      batch.delete('chunks_fts', where: 'chunk_id = ?', whereArgs: [id]);
    }
    await batch.commit(noResult: true);
  }

  /// BM25 keyword search via FTS5 with field-weighted ranking.
  ///
  /// Weights: topic=1.0, heading_path=2.0, body=1.5 — heading matches score
  /// higher than body matches, promoting sections whose title directly answers
  /// the query.
  ///
  /// Returns chunk IDs ranked by relevance (best first).
  Future<List<String>> searchFts(String query, {String? topicFilter, int limit = 20}) async {
    // FTS5 MATCH parses the query as a boolean expression — punctuation like
    // commas and "?" are invalid FTS5 syntax tokens and cause runtime errors.
    final sanitized = query
        .replaceAll(RegExp(r'[^\w\s]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (sanitized.isEmpty) return [];

    final database = await db;
    final topicClause = topicFilter != null ? 'AND topic = ?' : '';
    final args = topicFilter != null ? [sanitized, topicFilter, limit] : [sanitized, limit];
    final rows = await database.rawQuery(
      '''
      SELECT chunk_id FROM chunks_fts
      WHERE chunks_fts MATCH ?
      $topicClause
      ORDER BY bm25(chunks_fts, 1.0, 2.0, 1.5)
      LIMIT ?
      ''',
      args,
    );
    return rows.map((r) => r['chunk_id'] as String).toList();
  }

  // ── Dense retrieval (vector embeddings) ─────────────────────────────────────

  /// Store a precomputed embedding for a single chunk.
  ///
  /// Embeddings are stored as raw IEEE-754 float32 bytes (512 floats = 2,048
  /// bytes per chunk). For 300 chunks: ~614 KB total — negligible overhead.
  Future<void> updateChunkEmbedding(String chunkId, Float32List embedding) async {
    final database = await db;
    final bytes = embedding.buffer.asUint8List(
      embedding.offsetInBytes,
      embedding.lengthInBytes,
    );
    await database.update(
      'chunks',
      {'embedding': bytes},
      where: 'id = ?',
      whereArgs: [chunkId],
    );
  }

  /// Fetch all (chunkId, embedding) pairs where embeddings have been computed.
  ///
  /// Used by [RagService] to run brute-force cosine similarity at query time.
  /// The corpus is small (~300 chunks max) so loading all into Dart memory is
  /// efficient — the full payload is ≤614 KB.
  Future<List<(String, Float32List)>> getAllEmbeddings({
    String? topicFilter,
  }) async {
    final database = await db;
    final whereClause = topicFilter != null
        ? 'embedding IS NOT NULL AND topic = ?'
        : 'embedding IS NOT NULL';
    final rows = await database.rawQuery(
      'SELECT id, embedding FROM chunks WHERE $whereClause',
      topicFilter != null ? [topicFilter] : [],
    );
    return rows.map((r) {
      final blob = r['embedding'] as Uint8List;
      final f32 = Float32List.sublistView(
        ByteData.sublistView(blob),
      );
      return (r['id'] as String, f32);
    }).toList();
  }

  Future<List<DocChunk>> getChunksByIds(List<String> ids) async {
    if (ids.isEmpty) return [];
    final database = await db;
    final placeholders = ids.map((_) => '?').join(', ');
    final rows = await database.rawQuery(
      'SELECT * FROM chunks WHERE id IN ($placeholders)',
      ids,
    );
    // Preserve ranking order from [ids]
    final map = {for (final r in rows) r['id'] as String: DocChunk.fromMap(r)};
    return ids.map((id) => map[id]).whereType<DocChunk>().toList();
  }

  // ── Docs registry ────────────────────────────────────────────────────────────

  Future<void> upsertDoc(Map<String, dynamic> docMap) async {
    final database = await db;
    await database.insert('docs', docMap, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<String?> getDocVersion(String docId) async {
    final database = await db;
    final rows = await database.query('docs', columns: ['version'], where: 'id = ?', whereArgs: [docId]);
    return rows.isNotEmpty ? rows.first['version'] as String? : null;
  }

  Future<List<Map<String, dynamic>>> getDocsByTopic(String topic) async {
    final database = await db;
    return database.query('docs', where: 'topic = ?', whereArgs: [topic]);
  }

  Future<void> dispose() async {
    await _db?.close();
    _db = null;
  }
}
