import 'package:flutter_test/flutter_test.dart';
import 'package:survive_ai/models/chat_message.dart';
import 'package:survive_ai/utils/conversation.dart';

void main() {
  ChatMessage user(String text) =>
      ChatMessage(role: 'user', content: text, timestamp: DateTime.now());
  ChatMessage bot(String text) =>
      ChatMessage(role: 'assistant', content: text, timestamp: DateTime.now());

  final history = [
    user('my friend was bitten by a snake in the field'),
    bot('Get to a hospital that stocks ASV.'),
  ];

  group('Conversation.retrievalQuery', () {
    test('bare returns the turn unchanged', () {
      expect(
        Conversation.retrievalQuery(
          'should I tie it',
          history,
          strategy: TurnStrategy.bare,
        ),
        'should I tie it',
      );
    });

    test('window carries the opening question', () {
      final query = Conversation.retrievalQuery(
        'should I tie it',
        history,
        strategy: TurnStrategy.window,
      );

      expect(query, contains('snake'));
      expect(query, contains('tie'));
    });

    test('anchored keeps topic terms and drops filler', () {
      // A follow-up with no topic word needs the topic from earlier turns —
      // but a long conversation must not drown the current question.
      final query = Conversation.retrievalQuery(
        'should I tie it',
        history,
        vocabulary: {'snake', 'field'},
      );

      expect(query, contains('snake'));
      expect(query.split(' '), isNot(contains('was')));
      expect(query.split(' '), isNot(contains('the')));
    });

    test('anchored only draws on the user, never the model', () {
      // Otherwise the model's own wording steers the next retrieval, and an
      // early wrong answer compounds across the conversation.
      final query = Conversation.retrievalQuery(
        'what next',
        [
          user('flooding in my colony'),
          bot('Move to the terrace immediately.'),
        ],
        vocabulary: {'flooding', 'colony', 'terrace'},
      );

      expect(query, contains('flooding'));
      expect(query, isNot(contains('terrace')));
    });

    test('falls back to the turn when history has no topic terms', () {
      expect(
        Conversation.retrievalQuery('what now', [user('hello there')]),
        'what now',
      );
    });

    test('the first turn is identical under every strategy', () {
      for (final strategy in TurnStrategy.values) {
        expect(
          Conversation.retrievalQuery('snake bite', [], strategy: strategy),
          'snake bite',
        );
      }
    });

    test('Hinglish bridge words are carried without a corpus vocabulary', () {
      // The expansion table alone must be enough, since it is where romanised
      // Hindi lives.
      final query = Conversation.retrievalQuery('ab kya karu', [
        user('saanp ne kaata hai'),
      ]);

      expect(query, contains('saanp'));
    });

    test('carried terms are capped', () {
      final long = user(
        'snake bite blood wound fire flood water crowd fever burn shelter',
      );
      final query = Conversation.retrievalQuery('what now', [long]);

      expect(
        query.split(' ').length,
        lessThanOrEqualTo(2 + Conversation.maxAnchorTerms),
      );
    });
  });
}
