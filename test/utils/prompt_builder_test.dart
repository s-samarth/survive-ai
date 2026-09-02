import 'package:flutter_test/flutter_test.dart';
import 'package:survive_ai/models/chat_message.dart';
import 'package:survive_ai/models/doc_chunk.dart';
import 'package:survive_ai/services/llm_service.dart';
import 'package:survive_ai/utils/prompt_builder.dart';

void main() {
  DocChunk chunk(String id, String body) => DocChunk(
    id: id,
    docId: 'doc',
    topic: 'medical',
    headingPath: 'Part 1',
    body: body,
    chunkIndex: 0,
  );

  /// Same heuristic PromptBuilder uses internally: words x 1.3, rounded up.
  int estimateTokens(String text) =>
      (text.split(RegExp(r'\s+')).length * 1.3).ceil();

  group('PromptBuilder context budget', () {
    test('oversized context is trimmed, never discarded wholesale', () {
      // The bug this guards: when the reference block did not fit, the whole
      // block was dropped and the model answered from pretraining with nothing
      // retrieved — silent, and invisible to every metric that does not look
      // at the prompt.
      final chunks = List.generate(8, (i) => chunk('c$i', 'word ' * 400));

      final prompt = PromptBuilder.buildChatPrompt(
        chunks: chunks,
        history: [],
        userMessage: 'what do I do',
      );

      expect(prompt, contains('Reference information'));
      expect(estimateTokens(prompt), lessThanOrEqualTo(kMaxPromptTokens));
    });

    test('keeps the best chunks and drops the tail', () {
      final chunks = List.generate(8, (i) => chunk('c$i', 'body$i ' * 200));

      final selected = PromptBuilder.selectContextChunks(
        chunks: chunks,
        history: [],
        userMessage: 'what do I do',
      );

      expect(selected, isNotEmpty);
      expect(selected.length, lessThan(chunks.length));
      expect(selected.first.id, 'c0');
    });

    test('always keeps at least one chunk', () {
      // An oversized best chunk still beats sending nothing at all.
      final selected = PromptBuilder.selectContextChunks(
        chunks: [chunk('huge', 'word ' * 5000)],
        history: [],
        userMessage: 'what do I do',
      );

      expect(selected, hasLength(1));
    });

    test('history is never crowded out by a long reference block', () {
      final chunks = List.generate(8, (i) => chunk('c$i', 'word ' * 400));
      final history = [
        ChatMessage(
          role: 'user',
          content: 'first question',
          timestamp: DateTime.now(),
        ),
        ChatMessage(
          role: 'assistant',
          content: 'first answer',
          timestamp: DateTime.now(),
        ),
      ];

      final prompt = PromptBuilder.buildChatPrompt(
        chunks: chunks,
        history: history,
        userMessage: 'follow up',
      );

      expect(prompt, contains('Reference information'));
      expect(prompt, contains('Previous exchange'));
      expect(estimateTokens(prompt), lessThanOrEqualTo(kMaxPromptTokens));
    });

    test('more retrieved chunks never means less context', () {
      // The precise shape of the old bug: raising top_k collapsed the prompt.
      String promptFor(int n) => PromptBuilder.buildChatPrompt(
        chunks: List.generate(n, (i) => chunk('c$i', 'word ' * 300)),
        history: [],
        userMessage: 'what do I do',
      );

      expect(
        estimateTokens(promptFor(8)),
        greaterThanOrEqualTo(estimateTokens(promptFor(4))),
      );
    });

    test('citations can only reference chunks the model actually saw', () {
      final chunks = List.generate(10, (i) => chunk('c$i', 'word ' * 300));

      final selected = PromptBuilder.selectContextChunks(
        chunks: chunks,
        history: [],
        userMessage: 'what do I do',
      );
      final prompt = PromptBuilder.buildChatPrompt(
        chunks: chunks,
        history: [],
        userMessage: 'what do I do',
      );

      for (final c in selected) {
        expect(prompt, contains(c.body.substring(0, 20)));
      }
    });
  });

  group('PromptBuilder.buildChatPrompt', () {
    test('does not include turn markers (flutter_gemma adds them)', () {
      final prompt = PromptBuilder.buildChatPrompt(
        chunks: [],
        history: [],
        userMessage: 'How do I find water?',
      );

      expect(prompt, isNot(contains('<start_of_turn>')));
      expect(prompt, isNot(contains('<end_of_turn>')));
    });

    test('includes instruction and Survive AI identity', () {
      final prompt = PromptBuilder.buildChatPrompt(
        chunks: [],
        history: [],
        userMessage: 'test',
      );

      expect(prompt, contains('Survive AI'));
      expect(prompt, contains('survival'));
    });

    test('injects context from chunks as reference material', () {
      final chunks = [
        const DocChunk(
          id: 'c1',
          docId: 'water_doc',
          topic: 'jungle',
          headingPath: 'Finding Water',
          body: 'Look for flowing streams in dense vegetation areas.',
          chunkIndex: 0,
        ),
      ];

      final prompt = PromptBuilder.buildChatPrompt(
        chunks: chunks,
        history: [],
        userMessage: 'How do I find water?',
      );

      expect(prompt, contains('Reference information'));
      expect(prompt, contains('flowing streams'));
      expect(prompt, contains('jungle'));
    });

    test('omits reference block when no chunks provided', () {
      final prompt = PromptBuilder.buildChatPrompt(
        chunks: [],
        history: [],
        userMessage: 'test',
      );

      expect(prompt, isNot(contains('Reference information')));
    });

    test('trims history to last 4 turns', () {
      final history = List.generate(
        10,
        (i) => ChatMessage(
          role: i.isEven ? 'user' : 'assistant',
          content: 'Message $i',
          timestamp: DateTime.now(),
        ),
      );

      final prompt = PromptBuilder.buildChatPrompt(
        chunks: [],
        history: history,
        userMessage: 'current question',
      );

      // Should not contain early messages (only last 4 kept)
      expect(prompt, isNot(contains('Message 0')));
      expect(prompt, isNot(contains('Message 1')));
      expect(prompt, isNot(contains('Message 2')));
      expect(prompt, isNot(contains('Message 3')));
      expect(prompt, isNot(contains('Message 4')));
      expect(prompt, isNot(contains('Message 5')));
      // Should contain last 4 messages
      expect(prompt, contains('Message 6'));
      expect(prompt, contains('Message 9'));
    });

    test('ends with user question', () {
      final prompt = PromptBuilder.buildChatPrompt(
        chunks: [],
        history: [],
        userMessage: 'How do I stop bleeding?',
      );

      expect(prompt.trimRight(), endsWith('Question: How do I stop bleeding?'));
    });

    test('places instruction after context and before question', () {
      final chunks = [
        const DocChunk(
          id: 'c1',
          docId: 'doc1',
          topic: 'medical',
          headingPath: 'Bleeding',
          body: 'Apply pressure to the wound.',
          chunkIndex: 0,
        ),
      ];

      final prompt = PromptBuilder.buildChatPrompt(
        chunks: chunks,
        history: [],
        userMessage: 'How do I stop bleeding?',
      );

      final contextPos = prompt.indexOf('Apply pressure');
      final instructionPos = prompt.indexOf('Survive AI');
      final questionPos = prompt.indexOf('Question:');

      // Context first, then instruction, then question
      expect(contextPos, lessThan(instructionPos));
      expect(instructionPos, lessThan(questionPos));
    });

    test('uses Q/A format for history', () {
      final history = [
        ChatMessage(
          role: 'user',
          content: 'previous question',
          timestamp: DateTime.now(),
        ),
        ChatMessage(
          role: 'assistant',
          content: 'previous answer',
          timestamp: DateTime.now(),
        ),
      ];

      final prompt = PromptBuilder.buildChatPrompt(
        chunks: [],
        history: history,
        userMessage: 'follow up',
      );

      expect(prompt, contains('Q: previous question'));
      expect(prompt, contains('A: previous answer'));
      expect(prompt, contains('Previous exchange:'));
    });
  });
}
