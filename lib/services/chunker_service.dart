import 'package:uuid/uuid.dart';
import '../models/doc_chunk.dart';

const _uuid = Uuid();

/// Splits a Markdown document into chunks suitable for RAG retrieval.
///
/// Strategy (in order of preference):
/// 1. Split at h2/h3 heading boundaries first
/// 2. If a section still exceeds [maxTokens], split at blank lines (paragraphs)
/// 3. Apply [overlapTokens] of overlap between consecutive chunks
///
/// "Tokens" here are approximated as word count × 1.3 (rough GPT-style estimate).
class ChunkerService {
  final int maxTokens;
  final int overlapTokens;

  const ChunkerService({this.maxTokens = 300, this.overlapTokens = 50});

  List<DocChunk> chunk(String markdown, String docId, String topic) {
    final sections = _splitAtHeadings(markdown);
    final chunks = <DocChunk>[];
    var chunkIndex = 0;

    for (final section in sections) {
      final headingPath = section.heading;
      final paragraphs = _splitAtParagraphs(section.body);

      final window = <String>[];
      int windowTokens = 0;

      for (final para in paragraphs) {
        final paraTokens = _estimateTokens(para);

        if (windowTokens + paraTokens > maxTokens && window.isNotEmpty) {
          // Emit current window as a chunk
          chunks.add(
            _makeChunk(
              docId: docId,
              topic: topic,
              headingPath: headingPath,
              body: window.join('\n\n'),
              index: chunkIndex++,
            ),
          );

          // Overlap: keep last [overlapTokens] worth of content
          _applyOverlap(window, overlapTokens);
          windowTokens = window.fold(0, (acc, p) => acc + _estimateTokens(p));
        }

        window.add(para);
        windowTokens += paraTokens;
      }

      if (window.isNotEmpty) {
        chunks.add(
          _makeChunk(
            docId: docId,
            topic: topic,
            headingPath: headingPath,
            body: window.join('\n\n'),
            index: chunkIndex++,
          ),
        );
      }
    }

    return chunks;
  }

  DocChunk _makeChunk({
    required String docId,
    required String topic,
    required String headingPath,
    required String body,
    required int index,
  }) => DocChunk(
    id: _uuid.v4(),
    docId: docId,
    topic: topic,
    headingPath: headingPath,
    body: body.trim(),
    chunkIndex: index,
  );

  List<_Section> _splitAtHeadings(String markdown) {
    final sections = <_Section>[];
    final headingRegex = RegExp(r'^#{1,3}\s+(.+)$', multiLine: true);
    final matches = headingRegex.allMatches(markdown).toList();

    if (matches.isEmpty) {
      return [_Section(heading: '', body: markdown)];
    }

    // Text before the first heading
    if (matches.first.start > 0) {
      sections.add(
        _Section(heading: '', body: markdown.substring(0, matches.first.start)),
      );
    }

    for (var i = 0; i < matches.length; i++) {
      final heading = matches[i].group(1)!.trim();
      final start = matches[i].end;
      final end = i + 1 < matches.length
          ? matches[i + 1].start
          : markdown.length;
      sections.add(
        _Section(heading: heading, body: markdown.substring(start, end)),
      );
    }

    return sections;
  }

  List<String> _splitAtParagraphs(String text) {
    return text
        .split(RegExp(r'\n{2,}'))
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toList();
  }

  void _applyOverlap(List<String> window, int targetTokens) {
    while (window.isNotEmpty) {
      final total = window.fold(0, (acc, p) => acc + _estimateTokens(p));
      if (total <= targetTokens) break;
      window.removeAt(0);
    }
  }

  /// Rough token estimate: words × 1.3
  int _estimateTokens(String text) =>
      (text.split(RegExp(r'\s+')).length * 1.3).ceil();
}

class _Section {
  final String heading;
  final String body;
  const _Section({required this.heading, required this.body});
}
