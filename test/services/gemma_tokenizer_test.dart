import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:survive_ai/services/embedding/gemma_tokenizer.dart';

/// The shipped tokenizer, read from disk rather than through `rootBundle`:
/// asset mocking in a unit test falls through to the real bundle, and a test
/// that passes for that reason is worse than no test.
GemmaTokenizer? _load() {
  final file = File('assets/index/tokenizer.bin');
  if (!file.existsSync()) return null;
  final bytes = file.readAsBytesSync();
  return GemmaTokenizer.parse(ByteData.sublistView(bytes));
}

void main() {
  final tokenizer = _load();
  final fixture = File('test/fixtures/tokenizer_cases.json');

  group('GemmaTokenizer', () {
    test('matches the Python encoder that embedded the shipped passages', () {
      // This is the load-bearing test of the whole dense leg. The passage
      // vectors in assets/index/passages.f32 were produced offline by the
      // Python tokenizer; if this Dart port splits a query differently, the
      // query lands somewhere else in the same space and retrieval quietly
      // degrades with nothing to point at. Nothing throws when that happens,
      // so only an id-for-id comparison catches it.
      if (tokenizer == null || !fixture.existsSync()) {
        markTestSkipped('run `python -m survive_rag pack` to build artifacts');
        return;
      }
      final cases =
          (json.decode(fixture.readAsStringSync())
                  as Map<String, dynamic>)['cases']
              as List<dynamic>;
      expect(cases, isNotEmpty);

      for (final entry in cases.cast<Map<String, dynamic>>()) {
        final text = entry['text'] as String;
        final expected = (entry['ids'] as List<dynamic>).cast<int>();
        expect(
          tokenizer.encode(text),
          expected,
          reason: 'tokenization diverged for ${json.encode(text)}',
        );
      }
    });

    test('wraps every sequence in bos and eos', () {
      if (tokenizer == null) {
        markTestSkipped('no packed tokenizer');
        return;
      }
      final ids = tokenizer.encode('chest pain');
      expect(ids.first, tokenizer.bos);
      expect(ids.last, tokenizer.eos);
      expect(ids.length, greaterThan(2));
    });

    test('falls back to bytes rather than losing unknown characters', () {
      // Devanagari and emoji must survive as bytes. Collapsing them to <unk>
      // would strip an Indian-language query of the words it was asking about
      // and leave a vector with no signal in it.
      if (tokenizer == null) {
        markTestSkipped('no packed tokenizer');
        return;
      }
      final ids = tokenizer.encode('सांप');
      expect(ids.length, greaterThan(3));
      expect(ids, isNot(contains(tokenizer.bos + 1)));
    });

    test('caps a pasted wall of text instead of stalling', () {
      if (tokenizer == null) {
        markTestSkipped('no packed tokenizer');
        return;
      }
      final ids = tokenizer.encode('emergency ' * 5000);
      expect(ids.length, lessThanOrEqualTo(GemmaTokenizer.maxTokens));
    });

    test('rejects an artifact it does not understand', () {
      final wrong = ByteData(64)..setUint32(0, 0xDEADBEEF);
      expect(() => GemmaTokenizer.parse(wrong), throwsFormatException);
    });

    test('rejects a future format version rather than misreading it', () {
      final data = ByteData(64);
      for (final (i, b) in [0x47, 0x42, 0x50, 0x45].indexed) {
        data.setUint8(i, b);
      }
      data.setUint32(4, 99, Endian.little);
      expect(() => GemmaTokenizer.parse(data), throwsFormatException);
    });
  });
}
