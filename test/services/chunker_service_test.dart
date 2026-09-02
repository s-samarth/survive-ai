import 'package:flutter_test/flutter_test.dart';
import 'package:survive_ai/services/chunker_service.dart';

void main() {
  const chunker = ChunkerService(maxTokens: 300, overlapTokens: 50);

  group('ChunkerService', () {
    test('chunks simple markdown with no headings', () {
      const markdown =
          'This is a simple paragraph about finding water. '
          'Always look for flowing water first.\n\n'
          'Second paragraph about purification. '
          'Boiling water for at least one minute kills most pathogens.';

      final chunks = chunker.chunk(markdown, 'doc1', 'general');

      expect(chunks, isNotEmpty);
      expect(chunks.first.docId, 'doc1');
      expect(chunks.first.topic, 'general');
      expect(chunks.first.chunkIndex, 0);
    });

    test('splits at heading boundaries', () {
      const markdown = '''# Finding Water

Water is the most critical survival resource.

## Rainwater Collection

Set up tarps to collect rainwater during storms.

## Ground Water

Look for green vegetation which indicates underground water.
''';

      final chunks = chunker.chunk(markdown, 'water_doc', 'jungle');

      expect(chunks.length, greaterThanOrEqualTo(2));
      // Heading paths should be captured
      final headings = chunks.map((c) => c.headingPath).toSet();
      expect(headings, isNotEmpty);
    });

    test('respects maxTokens limit', () {
      // Create a long paragraph that should be split
      final longText = List.generate(200, (i) => 'word$i').join(' ');
      final markdown = '# Test\n\n$longText';

      final chunks = chunker.chunk(markdown, 'long_doc', 'general');

      for (final chunk in chunks) {
        // Each chunk body should not significantly exceed maxTokens
        final words = chunk.body.split(RegExp(r'\s+'));
        // Allow some overflow due to approximation (words * 1.3)
        expect(words.length, lessThan(400));
      }
    });

    test('handles empty markdown', () {
      final chunks = chunker.chunk('', 'empty', 'general');
      // Should return at most one empty chunk or nothing
      expect(chunks.length, lessThanOrEqualTo(1));
    });

    test('preserves chunk ordering via chunkIndex', () {
      const markdown = '''# Section A

Content for section A with enough text to matter.

# Section B

Content for section B with enough text to matter.

# Section C

Content for section C with enough text to matter.
''';

      final chunks = chunker.chunk(markdown, 'ordered', 'general');

      for (var i = 0; i < chunks.length; i++) {
        expect(chunks[i].chunkIndex, i);
      }
    });

    test('generates unique IDs for each chunk', () {
      const markdown = '''# A

Text alpha.

# B

Text beta.
''';

      final chunks = chunker.chunk(markdown, 'unique', 'general');
      final ids = chunks.map((c) => c.id).toSet();
      expect(ids.length, chunks.length, reason: 'All chunk IDs must be unique');
    });

    test('assigns correct topic and docId to all chunks', () {
      const markdown = '# Test\n\nSome content here.';
      final chunks = chunker.chunk(markdown, 'my_doc', 'medical');

      for (final chunk in chunks) {
        expect(chunk.docId, 'my_doc');
        expect(chunk.topic, 'medical');
      }
    });
  });
}
