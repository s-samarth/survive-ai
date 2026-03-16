import 'package:flutter_test/flutter_test.dart';
import 'package:survive_ai/models/chat_message.dart';
import 'package:survive_ai/models/doc_chunk.dart';
import 'package:survive_ai/utils/prompt_builder.dart';

void main() {
  group('PromptBuilder.buildChatPrompt', () {
    test('includes Gemma 3 format markers', () {
      final prompt = PromptBuilder.buildChatPrompt(
        chunks: [],
        history: [],
        userMessage: 'How do I find water?',
      );

      expect(prompt, contains('<start_of_turn>'));
      expect(prompt, contains('<end_of_turn>'));
      expect(prompt, contains('<start_of_turn> system'));
      expect(prompt, contains('<start_of_turn> user'));
      expect(prompt, contains('<start_of_turn> model'));
    });

    test('includes system prompt', () {
      final prompt = PromptBuilder.buildChatPrompt(
        chunks: [],
        history: [],
        userMessage: 'test',
      );

      expect(prompt, contains('Survive AI'));
      expect(prompt, contains('survival'));
    });

    test('injects context from chunks', () {
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

      expect(prompt, contains('[CONTEXT]'));
      expect(prompt, contains('[/CONTEXT]'));
      expect(prompt, contains('flowing streams'));
      expect(prompt, contains('jungle/water_doc'));
    });

    test('omits context block when no chunks provided', () {
      final prompt = PromptBuilder.buildChatPrompt(
        chunks: [],
        history: [],
        userMessage: 'test',
      );

      // The system prompt instruction text mentions [CONTEXT] generically,
      // but the actual context block with [/CONTEXT] should not appear.
      expect(prompt, isNot(contains('[/CONTEXT]')));
    });

    test('trims history to last 6 turns', () {
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

      // Should not contain early messages
      expect(prompt, isNot(contains('Message 0')));
      expect(prompt, isNot(contains('Message 1')));
      expect(prompt, isNot(contains('Message 2')));
      expect(prompt, isNot(contains('Message 3')));
      // Should contain later messages
      expect(prompt, contains('Message 4'));
      expect(prompt, contains('Message 9'));
    });

    test('ends with open model turn for generation', () {
      final prompt = PromptBuilder.buildChatPrompt(
        chunks: [],
        history: [],
        userMessage: 'test',
      );

      expect(prompt.endsWith('<start_of_turn> model\n'), isTrue);
    });
  });

}
