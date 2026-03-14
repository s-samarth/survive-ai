import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../models/doc_chunk.dart';
import '../models/action_plan.dart';

/// Owns the SQLite database: schema creation, migrations, and all CRUD.
///
/// Tables:
/// - chunks: raw chunk metadata + body
/// - chunks_fts: FTS5 virtual table for BM25 keyword search
/// - docs: document registry with sync state
/// - action_plans / action_steps: persistent situation-based checklists
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

    await db.execute('''
      CREATE TABLE action_plans (
        id TEXT PRIMARY KEY,
        created_at INTEGER NOT NULL,
        situation_json TEXT NOT NULL,
        is_active INTEGER NOT NULL DEFAULT 1
      )
    ''');

    await db.execute('''
      CREATE TABLE action_steps (
        id TEXT PRIMARY KEY,
        plan_id TEXT NOT NULL REFERENCES action_plans(id) ON DELETE CASCADE,
        step_index INTEGER NOT NULL,
        priority TEXT NOT NULL,
        title TEXT NOT NULL,
        detail TEXT NOT NULL,
        source_doc_id TEXT,
        is_completed INTEGER NOT NULL DEFAULT 0,
        completed_at INTEGER
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

  /// BM25 keyword search via FTS5.
  /// Returns chunk IDs ranked by relevance (best first).
  Future<List<String>> searchFts(String query, {String? topicFilter, int limit = 20}) async {
    final database = await db;
    final topicClause = topicFilter != null ? 'AND topic = ?' : '';
    final args = topicFilter != null ? [query, topicFilter, limit] : [query, limit];
    final rows = await database.rawQuery(
      '''
      SELECT chunk_id FROM chunks_fts
      WHERE chunks_fts MATCH ?
      $topicClause
      ORDER BY rank
      LIMIT ?
      ''',
      args,
    );
    return rows.map((r) => r['chunk_id'] as String).toList();
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

  Future<String?> getDocChecksum(String docId) async {
    final database = await db;
    final rows = await database.query('docs', columns: ['checksum'], where: 'id = ?', whereArgs: [docId]);
    return rows.isNotEmpty ? rows.first['checksum'] as String? : null;
  }

  Future<List<Map<String, dynamic>>> getDocsByTopic(String topic) async {
    final database = await db;
    return database.query('docs', where: 'topic = ?', whereArgs: [topic]);
  }

  // ── Action plans ─────────────────────────────────────────────────────────────

  Future<void> saveActionPlan(ActionPlan plan) async {
    final database = await db;
    final batch = database.batch();
    batch.insert('action_plans', {
      'id': plan.id,
      'created_at': plan.createdAt.millisecondsSinceEpoch,
      'situation_json': plan.situationJson.toString(),
      'is_active': plan.isActive ? 1 : 0,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    for (final step in plan.steps) {
      batch.insert('action_steps', step.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  Future<ActionPlan?> getActivePlan() async {
    final database = await db;
    final planRows = await database.query(
      'action_plans',
      where: 'is_active = 1',
      orderBy: 'created_at DESC',
      limit: 1,
    );
    if (planRows.isEmpty) return null;

    final planRow = planRows.first;
    final stepRows = await database.query(
      'action_steps',
      where: 'plan_id = ?',
      whereArgs: [planRow['id']],
      orderBy: 'step_index ASC',
    );
    return ActionPlan(
      id: planRow['id'] as String,
      createdAt: DateTime.fromMillisecondsSinceEpoch(planRow['created_at'] as int),
      situationJson: {},
      steps: stepRows.map(ActionStep.fromMap).toList(),
    );
  }

  Future<void> markStepCompleted(String stepId) async {
    final database = await db;
    await database.update(
      'action_steps',
      {'is_completed': 1, 'completed_at': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [stepId],
    );
  }

  Future<void> dispose() async {
    await _db?.close();
    _db = null;
  }
}
