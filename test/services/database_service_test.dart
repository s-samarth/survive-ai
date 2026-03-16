import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:survive_ai/models/doc_chunk.dart';

/// Initialize sqflite_common_ffi for desktop testing.
void _initFfi() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
}

/// Create an in-memory database with the same schema as DatabaseService.
Future<Database> _createInMemoryDb() async {
  return openDatabase(
    inMemoryDatabasePath,
    version: 1,
    onCreate: (db, version) async {
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
          doc_id TEXT NOT NULL,
          topic TEXT NOT NULL,
          heading_path TEXT NOT NULL DEFAULT '',
          body TEXT NOT NULL,
          chunk_index INTEGER NOT NULL,
          embedding BLOB
        )
      ''');
      await db.execute('''
        CREATE VIRTUAL TABLE chunks_fts USING fts5(
          chunk_id UNINDEXED,
          topic,
          heading_path,
          body,
          tokenize = 'porter ascii'
        )
      ''');
    },
  );
}

void main() {
  _initFfi();

  group('Database schema + CRUD', () {
    late Database db;

    setUp(() async {
      db = await _createInMemoryDb();
    });

    tearDown(() async {
      await db.close();
    });

    test('inserts and retrieves chunks', () async {
      final chunk = const DocChunk(
        id: 'chunk1',
        docId: 'water_doc',
        topic: 'jungle',
        headingPath: 'Finding Water',
        body: 'Look for flowing streams near vegetation.',
        chunkIndex: 0,
      );

      await db.insert('chunks', chunk.toMap());
      await db.insert('chunks_fts', {
        'chunk_id': chunk.id,
        'topic': chunk.topic,
        'heading_path': chunk.headingPath,
        'body': chunk.body,
      });

      final rows = await db.query('chunks', where: 'id = ?', whereArgs: ['chunk1']);
      expect(rows.length, 1);
      final retrieved = DocChunk.fromMap(rows.first);
      expect(retrieved.body, contains('flowing streams'));
    });

    test('FTS5 search finds relevant chunks', () async {
      // Insert seed data
      final chunks = [
        const DocChunk(id: 'c1', docId: 'doc1', topic: 'jungle', headingPath: '', body: 'Finding water in the jungle requires looking for streams and rivers.', chunkIndex: 0),
        const DocChunk(id: 'c2', docId: 'doc2', topic: 'medical', headingPath: '', body: 'Apply a tourniquet above the wound to stop arterial bleeding.', chunkIndex: 0),
        const DocChunk(id: 'c3', docId: 'doc3', topic: 'desert', headingPath: '', body: 'Conserve water by traveling at night and resting during daylight.', chunkIndex: 0),
      ];

      for (final c in chunks) {
        await db.insert('chunks', c.toMap());
        await db.insert('chunks_fts', {
          'chunk_id': c.id,
          'topic': c.topic,
          'heading_path': c.headingPath,
          'body': c.body,
        });
      }

      // Search for water-related content
      final results = await db.rawQuery(
        "SELECT chunk_id FROM chunks_fts WHERE chunks_fts MATCH ? ORDER BY rank LIMIT 4",
        ['water'],
      );
      final ids = results.map((r) => r['chunk_id'] as String).toList();

      expect(ids, isNotEmpty);
      // Both 'c1' and 'c3' mention water; 'c2' does not
      expect(ids, contains('c1'));
      expect(ids, contains('c3'));
      expect(ids, isNot(contains('c2')));
    });

    test('FTS5 search with topic filter', () async {
      final chunks = [
        const DocChunk(id: 'c1', docId: 'doc1', topic: 'jungle', headingPath: '', body: 'Water finding in jungle streams.', chunkIndex: 0),
        const DocChunk(id: 'c2', docId: 'doc2', topic: 'desert', headingPath: '', body: 'Water conservation in desert conditions.', chunkIndex: 0),
      ];

      for (final c in chunks) {
        await db.insert('chunks', c.toMap());
        await db.insert('chunks_fts', {
          'chunk_id': c.id,
          'topic': c.topic,
          'heading_path': c.headingPath,
          'body': c.body,
        });
      }

      final results = await db.rawQuery(
        "SELECT chunk_id FROM chunks_fts WHERE chunks_fts MATCH ? AND topic = ? ORDER BY rank LIMIT 4",
        ['water', 'jungle'],
      );
      final ids = results.map((r) => r['chunk_id'] as String).toList();

      expect(ids, equals(['c1']));
    });

    test('doc upsert and checksum retrieval', () async {
      await db.insert('docs', {
        'id': 'doc1',
        'filename': 'water_finding.md',
        'topic': 'jungle',
        'version': '1.0',
        'checksum': 'abc123',
        'last_synced': DateTime.now().millisecondsSinceEpoch,
      });

      final rows = await db.query('docs', columns: ['checksum'], where: 'id = ?', whereArgs: ['doc1']);
      expect(rows.first['checksum'], 'abc123');

      // Upsert (update)
      await db.insert(
        'docs',
        {
          'id': 'doc1',
          'filename': 'water_finding.md',
          'topic': 'jungle',
          'version': '1.1',
          'checksum': 'def456',
          'last_synced': DateTime.now().millisecondsSinceEpoch,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

      final updated = await db.query('docs', where: 'id = ?', whereArgs: ['doc1']);
      expect(updated.first['checksum'], 'def456');
      expect(updated.first['version'], '1.1');
    });
  });
}
