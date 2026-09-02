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
  static const _dbVersion = 3;

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
      onUpgrade: _onUpgrade,
    );
  }

  /// v1 -> v2: the topic taxonomy was replaced (generic biomes -> India-specific
  /// situations), so every row keyed on the old topics is meaningless. The corpus
  /// is re-seeded from bundled assets on the next launch, so dropping and
  /// recreating is both correct and faster than migrating.
  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      for (final t in ['chunks_ai', 'chunks_ad', 'chunks_au']) {
        await db.execute('DROP TRIGGER IF EXISTS $t');
      }
      await db.execute('DROP TABLE IF EXISTS chunks_fts');
      await db.execute('DROP TABLE IF EXISTS chunks');
      await db.execute('DROP TABLE IF EXISTS docs');
      await _onCreate(db, newVersion);
      return;
    }
    // v2 -> v3: retrieval moved from citation-sized chunks to ~320-token
    // passages, built offline by the Python indexer. `chunks` now holds
    // passages and `citations` holds the paragraphs they were built from, so
    // a link can still land on the sentence that answered the question. Every
    // existing row was chunked under the old policy and its ids no longer
    // mean anything, so the corpus is dropped and re-seeded from the bundled
    // index on the next launch.
    if (oldVersion < 3) {
      for (final t in ['chunks_ai', 'chunks_ad', 'chunks_au']) {
        await db.execute('DROP TRIGGER IF EXISTS $t');
      }
      await db.execute('DROP TABLE IF EXISTS citations');
      await db.execute('DROP TABLE IF EXISTS chunks_fts');
      await db.execute('DROP TABLE IF EXISTS chunks');
      await db.execute('DROP TABLE IF EXISTS docs');
      await _onCreate(db, newVersion);
    }
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

    // The paragraphs each passage was built from — what a citation points at.
    //
    // Retrieval scores passages because a 30-token prohibition holds too few
    // terms to match on its own; a citation must still land on a paragraph the
    // reader can be scrolled to. Ids are content-derived and produced by the
    // Python indexer, so a link means the same thing in the app, in the guide
    // reader and in an eval report.
    await db.execute('''
      CREATE TABLE citations (
        id TEXT PRIMARY KEY,
        chunk_id TEXT NOT NULL REFERENCES chunks(id) ON DELETE CASCADE,
        doc_id TEXT NOT NULL,
        topic TEXT NOT NULL,
        heading_path TEXT NOT NULL DEFAULT '',
        body TEXT NOT NULL,
        line_start INTEGER NOT NULL DEFAULT 0,
        line_end INTEGER NOT NULL DEFAULT 0,
        ordinal INTEGER NOT NULL DEFAULT 0,
        is_prohibition INTEGER NOT NULL DEFAULT 0
      )
    ''');

    await db.execute(
      'CREATE INDEX idx_citations_chunk ON citations(chunk_id)',
    );

    // FTS5 index over `chunks`, declared as an EXTERNAL CONTENT table.
    //
    // Previously this was a standalone table written to by hand alongside every
    // `chunks` write, with ConflictAlgorithm.replace. FTS5 virtual tables do not
    // honour conflict resolution — REPLACE inserts a duplicate row rather than
    // replacing — so re-syncing a doc silently doubled its index entries, and
    // the two tables could drift apart whenever one write succeeded and the
    // other did not.
    //
    // With content='chunks', FTS5 stores only the inverted index and reads
    // column values back from `chunks` (halving the database size, since bodies
    // are no longer duplicated). The triggers below are the only writer, so the
    // index cannot drift.
    //
    // porter stemmer normalizes: "running" -> "run", "wounds" -> "wound"
    await db.execute('''
      CREATE VIRTUAL TABLE chunks_fts USING fts5(
        topic,
        heading_path,
        body,
        content = 'chunks',
        content_rowid = 'rowid',
        tokenize = 'porter ascii'
      )
    ''');

    await db.execute('''
      CREATE TRIGGER chunks_ai AFTER INSERT ON chunks BEGIN
        INSERT INTO chunks_fts(rowid, topic, heading_path, body)
        VALUES (new.rowid, new.topic, new.heading_path, new.body);
      END
    ''');

    await db.execute('''
      CREATE TRIGGER chunks_ad AFTER DELETE ON chunks BEGIN
        INSERT INTO chunks_fts(chunks_fts, rowid, topic, heading_path, body)
        VALUES ('delete', old.rowid, old.topic, old.heading_path, old.body);
      END
    ''');

    await db.execute('''
      CREATE TRIGGER chunks_au AFTER UPDATE ON chunks
      WHEN old.body IS NOT new.body
        OR old.topic IS NOT new.topic
        OR old.heading_path IS NOT new.heading_path
      BEGIN
        INSERT INTO chunks_fts(chunks_fts, rowid, topic, heading_path, body)
        VALUES ('delete', old.rowid, old.topic, old.heading_path, old.body);
        INSERT INTO chunks_fts(rowid, topic, heading_path, body)
        VALUES (new.rowid, new.topic, new.heading_path, new.body);
      END
    ''');

    // Retrieval always filters or groups by topic, and sync deletes by doc.
    await db.execute('CREATE INDEX idx_chunks_topic ON chunks(topic)');
    await db.execute('CREATE INDEX idx_chunks_doc ON chunks(doc_id)');
  }

  // ── Chunks ──────────────────────────────────────────────────────────────────

  Future<void> insertChunks(List<DocChunk> chunks) async {
    final database = await db;
    final batch = database.batch();
    for (final chunk in chunks) {
      batch.insert(
        'chunks',
        chunk.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
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
  Future<List<String>> searchFts(
    String query, {
    String? topicFilter,
    int limit = 20,
  }) async {
    final matchExpr = buildMatchExpression(query);
    if (matchExpr == null) return [];

    final database = await db;
    final topicClause = topicFilter != null ? 'AND topic = ?' : '';
    final args = topicFilter != null
        ? [matchExpr, topicFilter, limit]
        : [matchExpr, limit];
    final rows = await database.rawQuery('''
      SELECT chunk_id FROM chunks_fts
      WHERE chunks_fts MATCH ?
      $topicClause
      ORDER BY bm25(chunks_fts, 1.0, 2.0, 1.5)
      LIMIT ?
      ''', args);
    return rows.map((r) => r['chunk_id'] as String).toList();
  }

  /// Turn a natural-language question into a valid FTS5 MATCH expression.
  ///
  /// FTS5's implicit operator between bare terms is **AND**, not OR. Passing
  /// a whole sentence to MATCH therefore demands that every word — including
  /// "how", "i", "from" — appear in the same ~300-token chunk, which returns
  /// nothing for virtually any real question. Terms are OR-joined instead, and
  /// BM25 ranking does the work of preferring chunks that match more of them.
  ///
  /// Each term is double-quoted so that FTS5 treats it as a literal string
  /// rather than as syntax (a query containing "or", "not", or "near" would
  /// otherwise be a syntax error at runtime).
  ///
  /// Returns null when nothing searchable is left.
  static String? buildMatchExpression(String query, {int maxTerms = 24}) {
    final terms = query
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9\s]'), ' ')
        .split(RegExp(r'\s+'))
        .where((t) => t.length > 1 && !_stopwords.contains(t))
        .toSet()
        .take(maxTerms)
        .toList();
    if (terms.isEmpty) return null;
    return terms.map((t) => '"$t"').join(' OR ');
  }

  /// Words that carry no retrieval signal but would otherwise dominate an
  /// OR query and pull in every chunk in the corpus.
  static const _stopwords = <String>{
    'a',
    'an',
    'and',
    'are',
    'as',
    'at',
    'be',
    'been',
    'but',
    'by',
    'can',
    'do',
    'does',
    'did',
    'for',
    'from',
    'get',
    'got',
    'had',
    'has',
    'have',
    'he',
    'her',
    'him',
    'his',
    'how',
    'i',
    'if',
    'in',
    'into',
    'is',
    'it',
    'its',
    'me',
    'my',
    'no',
    'not',
    'of',
    'on',
    'or',
    'our',
    'out',
    'over',
    'she',
    'should',
    'so',
    'some',
    'that',
    'the',
    'their',
    'them',
    'then',
    'there',
    'these',
    'they',
    'this',
    'to',
    'up',
    'us',
    'was',
    'we',
    'were',
    'what',
    'when',
    'where',
    'which',
    'who',
    'why',
    'will',
    'with',
    'would',
    'you',
    'your',
  };

  // ── Dense retrieval (vector embeddings) ─────────────────────────────────────

  /// Store a precomputed embedding for a single chunk.
  ///
  /// Embeddings are stored as raw IEEE-754 float32 bytes (512 floats = 2,048
  /// bytes per chunk). For 300 chunks: ~614 KB total — negligible overhead.
  Future<void> updateChunkEmbedding(
    String chunkId,
    Float32List embedding,
  ) async {
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
      final f32 = Float32List.sublistView(ByteData.sublistView(blob));
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
    await database.insert(
      'docs',
      docMap,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<String?> getDocVersion(String docId) async {
    final database = await db;
    final rows = await database.query(
      'docs',
      columns: ['version'],
      where: 'id = ?',
      whereArgs: [docId],
    );
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
