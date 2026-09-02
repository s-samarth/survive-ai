/// The manifest.json schema — fetched from GitHub on each WiFi sync.
/// Controls both the model download URL and the list of all survival docs.
class DocManifest {
  final String version;
  final ModelInfo model;

  /// The query encoder for the dense retrieval leg, when the manifest offers
  /// one. Optional and separately downloadable: the app answers without it on
  /// its two lexical legs, so an older manifest is a weaker build rather than
  /// a broken one.
  final List<ModelInfo> embedder;

  final List<DocEntry> docs;

  const DocManifest({
    required this.version,
    required this.model,
    required this.docs,
    this.embedder = const [],
  });

  factory DocManifest.fromJson(Map<String, dynamic> json) => DocManifest(
    version: json['version'] as String,
    model: ModelInfo.fromJson(json['model'] as Map<String, dynamic>),
    // A list because the ONNX graph and its weight sidecar are two files that
    // must land in the same directory under exact names; either alone is
    // useless, so they are fetched and checked as a set.
    embedder: ((json['embedder'] as List?) ?? const [])
        .map((e) => ModelInfo.fromJson(e as Map<String, dynamic>))
        .toList(),
    docs: (json['docs'] as List)
        .map((d) => DocEntry.fromJson(d as Map<String, dynamic>))
        .toList(),
  );
}

class ModelInfo {
  final String name;
  final String url;
  final int sizeBytes;

  /// Lowercase hex SHA-256 of the model file, used to reject a corrupt or
  /// truncated download before it is ever handed to the inference engine.
  /// Null in older manifests; the size check still applies.
  final String? sha256;

  /// Opaque version stamp. When it changes, clients re-download the model.
  final String version;

  const ModelInfo({
    required this.name,
    required this.url,
    required this.sizeBytes,
    this.sha256,
    this.version = '1',
  });

  factory ModelInfo.fromJson(Map<String, dynamic> json) => ModelInfo(
    name: json['name'] as String,
    url: json['url'] as String,
    sizeBytes: json['size_bytes'] as int,
    sha256: json['sha256'] as String?,
    version: json['version'] as String? ?? '1',
  );
}

class DocEntry {
  final String id;
  final String filename;
  final String topic;
  final String title;
  final String version;
  final String url;

  const DocEntry({
    required this.id,
    required this.filename,
    required this.topic,
    required this.title,
    required this.version,
    required this.url,
  });

  factory DocEntry.fromJson(Map<String, dynamic> json) => DocEntry(
    id: json['id'] as String,
    filename: json['filename'] as String,
    topic: json['topic'] as String,
    title: json['title'] as String,
    version: json['version'] as String,
    url: json['url'] as String,
  );
}
