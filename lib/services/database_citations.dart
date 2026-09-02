import 'package:sqflite/sqflite.dart';

import '../models/citation.dart';
import 'database_service.dart';

/// Citation storage, kept beside [DatabaseService] rather than inside it.
///
/// The chunk and document tables are one concern; the paragraphs a passage
/// was built from are another, added when retrieval moved to passage
/// granularity. Splitting them keeps each file readable and means a change to
/// citations cannot break FTS maintenance by accident.
extension DatabaseCitations on DatabaseService {
  /// Store the paragraphs a set of passages was built from.
  ///
  /// Written with `ignore` rather than `replace`: a citation id is derived
  /// from its content, so a collision means the same paragraph, and REPLACE on
  /// a table SQLite treats as a delete+insert would churn rows for nothing.
  Future<void> insertCitations(List<Citation> citations) async {
    if (citations.isEmpty) return;
    final database = await db;
    final batch = database.batch();
    for (final citation in citations) {
      batch.insert(
        'citations',
        citation.toMap(),
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
    await batch.commit(noResult: true);
  }

  /// The citable paragraphs inside [chunkIds], in document order.
  ///
  /// Used to turn a retrieved passage into a link the reader can follow, and
  /// to tell the answer guard which prohibitions were in the context.
  Future<List<Citation>> citationsForChunks(List<String> chunkIds) async {
    if (chunkIds.isEmpty) return const [];
    final database = await db;
    final placeholders = List.filled(chunkIds.length, '?').join(',');
    final rows = await database.query(
      'citations',
      where: 'chunk_id IN ($placeholders)',
      whereArgs: chunkIds,
      orderBy: 'chunk_id, ordinal',
    );
    return rows.map(Citation.fromMap).toList();
  }

  /// Delete every citation belonging to a document.
  Future<void> deleteCitationsForDoc(String docId) async {
    final database = await db;
    await database.delete('citations', where: 'doc_id = ?', whereArgs: [docId]);
  }
}
