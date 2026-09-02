import 'dart:typed_data';

/// A single chunk of a survival document, used by the RAG pipeline.
class DocChunk {
  final String id;
  final String docId;
  final String topic;
  final String headingPath; // e.g. "Finding Water > Rainwater Collection"
  final String body;
  final int chunkIndex;

  /// The dense vector for this chunk, when one shipped with the index.
  ///
  /// Computed offline: a phone never embeds a document, because the corpus is
  /// the same on every device and 201 forward passes at launch is a cost with
  /// nothing to buy. Null on a chunk synced from GitHub after the artifact was
  /// built, which the sync path then embeds on the device.
  final Float32List? embedding;

  const DocChunk({
    required this.id,
    required this.docId,
    required this.topic,
    required this.headingPath,
    required this.body,
    required this.chunkIndex,
    this.embedding,
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'doc_id': docId,
    'topic': topic,
    'heading_path': headingPath,
    'body': body,
    'chunk_index': chunkIndex,
    // Omitted rather than written as null, so an insert without a vector does
    // not overwrite one the index already supplied.
    //
    // The view's own window, not `.buffer`. Vectors arrive as slices of one
    // large file-backed buffer, and `.buffer` hands back the whole thing — so
    // every passage was storing the entire 603 KB vector file as its own
    // embedding. Nothing threw: cosine saw mismatched lengths, returned 0.0
    // for every pair, and the dense leg silently ranked every query the same.
    if (embedding != null)
      'embedding': Uint8List.view(
        embedding!.buffer,
        embedding!.offsetInBytes,
        embedding!.lengthInBytes,
      ),
  };

  factory DocChunk.fromMap(Map<String, dynamic> map) => DocChunk(
    id: map['id'] as String,
    docId: map['doc_id'] as String,
    topic: map['topic'] as String,
    headingPath: map['heading_path'] as String? ?? '',
    body: map['body'] as String,
    chunkIndex: map['chunk_index'] as int,
    embedding: map['embedding'] == null
        ? null
        : Float32List.sublistView(
            ByteData.sublistView(map['embedding'] as Uint8List),
          ),
  );
}
