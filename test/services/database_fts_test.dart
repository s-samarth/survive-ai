import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:survive_ai/models/doc_chunk.dart';
import 'package:survive_ai/services/database_service.dart';

/// Exercises the real [DatabaseService] against its own schema.
///
/// The existing database tests build the tables by hand and then run SQL
/// against them, which means `insertChunks`, `deleteChunksForDoc` and
/// `searchFts` were never executed by anything. All three named a `chunk_id`
/// column that the FTS table does not have, so keyword retrieval could not
/// return a single row on a device — and every test passed, because the
/// hand-written copy of the schema had the column the real one lacked.
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late DatabaseService db;
  late Directory scratch;

  DocChunk chunk(String id, String body, {String topic = 'medical'}) =>
      DocChunk(
        id: id,
        docId: 'guide-$topic',
        topic: topic,
        headingPath: 'Bleeding',
        body: body,
        chunkIndex: 0,
      );

  // A file per test rather than `inMemoryDatabasePath`: sqflite_ffi hands the
  // same in-memory database to every connection, so rows from one test showed
  // up in the next and a heading match made a filter assertion fail for a
  // reason that had nothing to do with the code under test.
  setUp(() {
    scratch = Directory.systemTemp.createTempSync('survive_ai_fts');
    db = DatabaseService(databasePath: '${scratch.path}/test.db');
  });
  tearDown(() => scratch.deleteSync(recursive: true));

  group('DatabaseService FTS, end to end', () {
    test('an inserted chunk is findable', () async {
      await db.insertChunks([chunk('c1', 'apply pressure to the wound')]);
      expect(await db.searchFts('wound'), ['c1']);
    });

    test('re-ingesting the corpus does not duplicate the index', () async {
      // The failure this guards is not an exception: BM25 scores drift as the
      // same document is counted twice, and retrieval quietly gets worse.
      for (var i = 0; i < 3; i++) {
        await db.insertChunks([chunk('c1', 'tourniquet above the wound')]);
      }
      expect(await db.searchFts('tourniquet'), ['c1']);
    });

    test('deleting a doc removes it from the index', () async {
      await db.insertChunks([chunk('c1', 'snake bite antivenom')]);
      await db.deleteChunksForDoc('guide-medical');
      expect(await db.searchFts('antivenom'), isEmpty);
    });

    test('the topic filter narrows results', () async {
      await db.insertChunks([
        chunk('c1', 'water is rising fast', topic: 'flood'),
        chunk('c2', 'water for a burn', topic: 'medical'),
      ]);
      expect(await db.searchFts('water', topicFilter: 'flood'), ['c1']);
    });

    test(
      'a whole question retrieves, rather than demanding every word',
      () async {
        // FTS5 ANDs bare terms, so an unprocessed sentence matches nothing.
        await db.insertChunks([
          chunk('c1', 'apply firm pressure to the wound'),
        ]);
        expect(await db.searchFts('how do I stop a wound from bleeding'), [
          'c1',
        ]);
      },
    );

    test('editing a chunk re-indexes it under its new text', () async {
      await db.insertChunks([chunk('c1', 'apply a tourniquet')]);
      await db.insertChunks([chunk('c1', 'apply direct pressure')]);
      expect(await db.searchFts('tourniquet'), isEmpty);
      expect(await db.searchFts('pressure'), ['c1']);
    });
  });
}
