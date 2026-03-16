import 'package:flutter_test/flutter_test.dart';
import 'package:survive_ai/models/chat_message.dart';
import 'package:survive_ai/models/doc_chunk.dart';
import 'package:survive_ai/utils/prompt_builder.dart';

void main() {
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
      final history = List.generate(10, (i) => ChatMessage(
        role: i.isEven ? 'user' : 'assistant',
        content: 'Message $i',
        timestamp: DateTime.now(),
      ));

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
