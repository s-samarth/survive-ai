import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:survive_ai/models/doc_chunk.dart';
import 'package:survive_ai/services/database_service.dart';

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

      final rows = await db.query(
        'chunks',
        where: 'id = ?',
        whereArgs: ['chunk1'],
      );
      expect(rows.length, 1);
      final retrieved = DocChunk.fromMap(rows.first);
      expect(retrieved.body, contains('flowing streams'));
    });

    test('FTS5 search finds relevant chunks', () async {
      // Insert seed data
      final chunks = [
        const DocChunk(
          id: 'c1',
          docId: 'doc1',
          topic: 'jungle',
          headingPath: '',
          body:
              'Finding water in the jungle requires looking for streams and rivers.',
          chunkIndex: 0,
        ),
        const DocChunk(
          id: 'c2',
          docId: 'doc2',
          topic: 'medical',
          headingPath: '',
          body: 'Apply a tourniquet above the wound to stop arterial bleeding.',
          chunkIndex: 0,
        ),
        const DocChunk(
          id: 'c3',
          docId: 'doc3',
          topic: 'desert',
          headingPath: '',
          body:
              'Conserve water by traveling at night and resting during daylight.',
          chunkIndex: 0,
        ),
      ];

      for (final c in chunks) {
        await db.insert('chunks', c.toMap());
      }

      // Search for water-related content
      final results = await db.rawQuery(
        "SELECT c.id AS id FROM chunks_fts f JOIN chunks c ON c.rowid = f.rowid "
        "WHERE chunks_fts MATCH ? ORDER BY rank LIMIT 4",
        ['water'],
      );
      final ids = results.map((r) => r['id'] as String).toList();

      expect(ids, isNotEmpty);
      // Both 'c1' and 'c3' mention water; 'c2' does not
      expect(ids, contains('c1'));
      expect(ids, contains('c3'));
      expect(ids, isNot(contains('c2')));
    });

    test('FTS5 search with topic filter', () async {
      final chunks = [
        const DocChunk(
          id: 'c1',
          docId: 'doc1',
          topic: 'jungle',
          headingPath: '',
          body: 'Water finding in jungle streams.',
          chunkIndex: 0,
        ),
        const DocChunk(
          id: 'c2',
          docId: 'doc2',
          topic: 'desert',
          headingPath: '',
          body: 'Water conservation in desert conditions.',
          chunkIndex: 0,
        ),
      ];

      for (final c in chunks) {
        await db.insert('chunks', c.toMap());
      }

      final results = await db.rawQuery(
        "SELECT c.id AS id FROM chunks_fts f JOIN chunks c ON c.rowid = f.rowid "
        "WHERE chunks_fts MATCH ? AND c.topic = ? ORDER BY rank LIMIT 4",
        ['water', 'jungle'],
      );
      final ids = results.map((r) => r['id'] as String).toList();

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

      final rows = await db.query(
        'docs',
        columns: ['checksum'],
        where: 'id = ?',
        whereArgs: ['doc1'],
      );
      expect(rows.first['checksum'], 'abc123');

      // Upsert (update)
      await db.insert('docs', {
        'id': 'doc1',
        'filename': 'water_finding.md',
        'topic': 'jungle',
        'version': '1.1',
        'checksum': 'def456',
        'last_synced': DateTime.now().millisecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.replace);

      final updated = await db.query(
        'docs',
        where: 'id = ?',
        whereArgs: ['doc1'],
      );
      expect(updated.first['checksum'], 'def456');
      expect(updated.first['version'], '1.1');
    });
  });

  group('buildMatchExpression', () {
    test('OR-joins terms so a full sentence still matches', () {
      final expr = DatabaseService.buildMatchExpression(
        'how do I stop bleeding from a deep cut?',
      );
      expect(expr, isNotNull);
      expect(expr, contains(' OR '));
      expect(expr, contains('"bleeding"'));
      expect(expr, contains('"cut"'));
    });

    test('drops stopwords that would match every chunk', () {
      final expr = DatabaseService.buildMatchExpression(
        'how do I stop bleeding from a deep cut?',
      )!;
      for (final stop in ['"how"', '"do"', '"i"', '"from"', '"a"']) {
        expect(expr, isNot(contains(stop)));
      }
    });

    test('quotes terms so FTS5 keywords are not parsed as syntax', () {
      // "near" and "not" are FTS5 operators; unquoted they are a syntax error.
      final expr = DatabaseService.buildMatchExpression(
        'fire near me not far',
      )!;
      expect(expr, contains('"fire"'));
      expect(expr, isNot(contains(' NEAR ')));
    });

    test('returns null when nothing searchable remains', () {
      expect(DatabaseService.buildMatchExpression('?!'), isNull);
      expect(DatabaseService.buildMatchExpression('how do I'), isNull);
    });
  });

  group('FTS5 natural-language retrieval', () {
    late Database db;

    setUp(() async {
      db = await _createInMemoryDb();
      final chunks = [
        const DocChunk(
          id: 'c1',
          docId: 'medical_guide',
          topic: 'medical',
          headingPath: 'Severe Bleeding',
          body:
              'Press hard directly on the wound with a clean cloth. '
              'Hold pressure for ten full minutes before checking.',
          chunkIndex: 0,
        ),
        const DocChunk(
          id: 'c2',
          docId: 'fire_guide',
          topic: 'fire',
          headingPath: 'Escaping Smoke',
          body:
              'Stay low and crawl. Smoke and hot gases collect near the '
              'ceiling. Close every door behind you.',
          chunkIndex: 0,
        ),
      ];
      for (final c in chunks) {
        await db.insert('chunks', c.toMap());
      }
    });

    tearDown(() async => db.close());

    Future<List<String>> search(String query) async {
      final expr = DatabaseService.buildMatchExpression(query);
      if (expr == null) return [];
      final rows = await db.rawQuery(
        'SELECT c.id AS id FROM chunks_fts f JOIN chunks c ON c.rowid = f.rowid '
        'WHERE chunks_fts MATCH ? '
        'ORDER BY bm25(chunks_fts, 1.0, 2.0, 1.5) LIMIT 4',
        [expr],
      );
      return rows.map((r) => r['id'] as String).toList();
    }

    test('a full sentence retrieves the right chunk', () async {
      // Regression: the raw sentence was previously passed to MATCH, where
      // FTS5's implicit AND required every word in one chunk and returned
      // nothing for any real question.
      expect(
        await search('how do I stop bleeding from a deep cut'),
        contains('c1'),
      );
      expect(
        await search('the room is full of smoke what do I do'),
        contains('c2'),
      );
    });

    test('raw sentence via implicit AND would have returned nothing', () async {
      final rows = await db.rawQuery(
        'SELECT rowid FROM chunks_fts WHERE chunks_fts MATCH ?',
        ['how do I stop bleeding from a deep cut'],
      );
      expect(rows, isEmpty);
    });
  });

  group('FTS index stays in sync with chunks (trigger-maintained)', () {
    late Database db;

    setUp(() async => db = await _createInMemoryDb());
    tearDown(() async => db.close());

    Future<int> ftsRowsMatching(String term) async {
      final rows = await db.rawQuery(
        'SELECT rowid FROM chunks_fts WHERE chunks_fts MATCH ?',
        [term],
      );
      return rows.length;
    }

    DocChunk chunk(String id, String body) => DocChunk(
      id: id,
      docId: 'guide',
      topic: 'medical',
      headingPath: 'Bleeding',
      body: body,
      chunkIndex: 0,
    );

    test('insert indexes the chunk without a manual FTS write', () async {
      await db.insert(
        'chunks',
        chunk('c1', 'tourniquet above the wound').toMap(),
      );
      expect(await ftsRowsMatching('tourniquet'), 1);
    });

    test(
      're-ingesting the same chunk id does not duplicate the index',
      () async {
        // Mirrors DatabaseService.insertChunks: explicit DELETE then INSERT.
        // Regression for the sync path — the index used to grow by a full copy
        // of the corpus on every re-ingest, quietly skewing BM25 scores.
        for (var i = 0; i < 3; i++) {
          await db.delete('chunks', where: 'id = ?', whereArgs: ['c1']);
          await db.insert(
            'chunks',
            chunk('c1', 'tourniquet above the wound').toMap(),
          );
        }
        expect(await ftsRowsMatching('tourniquet'), 1);
      },
    );

    test('SQLite REPLACE would silently duplicate the index', () async {
      // Documents exactly why insertChunks does delete-then-insert rather than
      // using ConflictAlgorithm.replace: REPLACE conflict resolution skips
      // DELETE triggers, so the old FTS row is orphaned under its old rowid
      // and a second one is appended.
      for (var i = 0; i < 3; i++) {
        await db.insert(
          'chunks',
          chunk('c1', 'tourniquet above the wound').toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      expect(await ftsRowsMatching('tourniquet'), 3);
    });

    test('deleting a doc removes its index entries', () async {
      await db.insert(
        'chunks',
        chunk('c1', 'tourniquet above the wound').toMap(),
      );
      await db.insert(
        'chunks',
        chunk('c2', 'crawl low under the smoke').toMap(),
      );
      await db.delete('chunks', where: 'doc_id = ?', whereArgs: ['guide']);
      expect(await ftsRowsMatching('tourniquet'), 0);
      expect(await ftsRowsMatching('smoke'), 0);
    });

    test('updating a chunk body reindexes it', () async {
      await db.insert(
        'chunks',
        chunk('c1', 'tourniquet above the wound').toMap(),
      );
      await db.update(
        'chunks',
        {'body': 'direct pressure with a clean cloth'},
        where: 'id = ?',
        whereArgs: ['c1'],
      );
      expect(await ftsRowsMatching('tourniquet'), 0);
      expect(await ftsRowsMatching('pressure'), 1);
    });
  });
}
