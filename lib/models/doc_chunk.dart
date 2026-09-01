/// A single chunk of a survival document, used by the RAG pipeline.
class DocChunk {
  final String id;
  final String docId;
  final String topic;
  final String headingPath; // e.g. "Finding Water > Rainwater Collection"
  final String body;
  final int chunkIndex;

  const DocChunk({
    required this.id,
    required this.docId,
    required this.topic,
    required this.headingPath,
    required this.body,
    required this.chunkIndex,
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'doc_id': docId,
    'topic': topic,
    'heading_path': headingPath,
    'body': body,
    'chunk_index': chunkIndex,
  };

  factory DocChunk.fromMap(Map<String, dynamic> map) => DocChunk(
    id: map['id'] as String,
    docId: map['doc_id'] as String,
    topic: map['topic'] as String,
    headingPath: map['heading_path'] as String? ?? '',
    body: map['body'] as String,
    chunkIndex: map['chunk_index'] as int,
  );
}
