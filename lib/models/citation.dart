/// One addressable paragraph of a guide — what a citation points at.
///
/// Retrieval scores *passages* (~320 tokens), because a 30-token prohibition
/// holds too few terms to match on its own. But a citation has to land on a
/// paragraph the reader can be scrolled to and recognise, so every passage
/// keeps the children it was built from.
///
/// Ids are content-derived and built once, offline, by the Python indexer:
/// `topic#heading-slug#block-slug`. Inserting a paragraph above does not
/// renumber the citations below it, so a link keeps meaning the same thing
/// across guide edits, app versions and eval reports.
class Citation {
  const Citation({
    required this.id,
    required this.chunkId,
    required this.docId,
    required this.topic,
    required this.headingPath,
    required this.body,
    required this.lineStart,
    required this.lineEnd,
    required this.ordinal,
    this.isProhibition = false,
  });

  /// Stable `topic#heading#block` identifier.
  final String id;

  /// The passage that contains this paragraph, i.e. what retrieval scored.
  final String chunkId;

  final String docId;
  final String topic;
  final String headingPath;
  final String body;

  /// 1-based source line range, for deep-linking into the guide reader.
  final int lineStart;
  final int lineEnd;

  /// Position within the parent section.
  final int ordinal;

  /// True when this paragraph states something the reader must NOT do.
  ///
  /// Carried into the app because the answer guard needs to know which
  /// prohibitions were in the context the model was given.
  final bool isProhibition;

  factory Citation.fromIndex(Map<String, dynamic> row, String chunkId) {
    return Citation(
      id: row['chunk_id'] as String,
      chunkId: chunkId,
      docId: (row['topic'] as String),
      topic: row['topic'] as String,
      headingPath: row['heading_path'] as String? ?? '',
      body: row['text'] as String,
      lineStart: row['line_start'] as int? ?? 0,
      lineEnd: row['line_end'] as int? ?? 0,
      ordinal: row['ordinal'] as int? ?? 0,
      isProhibition: row['is_prohibition'] as bool? ?? false,
    );
  }

  /// Same citation, attributed to a document id.
  ///
  /// The artifact keys everything by topic; the database keys by doc.
  Citation copyWithDoc(String docId) => Citation(
    id: id,
    chunkId: chunkId,
    docId: docId,
    topic: topic,
    headingPath: headingPath,
    body: body,
    lineStart: lineStart,
    lineEnd: lineEnd,
    ordinal: ordinal,
    isProhibition: isProhibition,
  );

  Map<String, Object?> toMap() => {
    'id': id,
    'chunk_id': chunkId,
    'doc_id': docId,
    'topic': topic,
    'heading_path': headingPath,
    'body': body,
    'line_start': lineStart,
    'line_end': lineEnd,
    'ordinal': ordinal,
    'is_prohibition': isProhibition ? 1 : 0,
  };

  factory Citation.fromMap(Map<String, dynamic> map) => Citation(
    id: map['id'] as String,
    chunkId: map['chunk_id'] as String,
    docId: map['doc_id'] as String,
    topic: map['topic'] as String,
    headingPath: map['heading_path'] as String? ?? '',
    body: map['body'] as String,
    lineStart: map['line_start'] as int? ?? 0,
    lineEnd: map['line_end'] as int? ?? 0,
    ordinal: map['ordinal'] as int? ?? 0,
    isProhibition: (map['is_prohibition'] as int? ?? 0) == 1,
  );
}
