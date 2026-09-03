import 'package:flutter_test/flutter_test.dart';
import 'package:survive_ai/utils/app_responses.dart';
import 'package:survive_ai/utils/query_router.dart';

void main() {
  group('QueryRouter capability detection', () {
    for (final query in [
      'what can you do',
      'how can you help me',
      'who are you',
      'what is this app',
      'hello',
      'namaste',
      'aap kya kar sakte ho',
      'tum kaun ho',
      'help',
    ]) {
      test('recognises "$query"', () {
        // Usually someone's first message, so it is the first impression.
        expect(QueryRouter.looksLikeCapabilityQuestion(query), isTrue);
      });
    }

    for (final query in [
      'should I tie a tourniquet on a snake bite',
      'khoon nikal raha hai',
      'chest pain',
      'aag lag gayi hai',
    ]) {
      test('does not match the emergency "$query"', () {
        // A false match would answer a snakebite with a help screen.
        expect(QueryRouter.looksLikeCapabilityQuestion(query), isFalse);
      });
    }
  });

  group('QueryRouter.route', () {
    test('high confidence beats a capability phrase', () {
      final route = QueryRouter.route(
        'what can you do about a snake bite',
        confidence: 0.62,
      );
      expect(route.intent, QueryIntent.answer);
    });

    test('capability wins at ordinary confidence', () {
      // Capability queries measured 0.19–0.36, straddling the answer
      // threshold, so the pattern has to decide.
      final route = QueryRouter.route('what can you do', confidence: 0.33);
      expect(route.intent, QueryIntent.capability);
    });

    test('low confidence declines', () {
      final route = QueryRouter.route(
        'how do I invest in mutual funds',
        confidence: 0.12,
      );
      expect(route.intent, QueryIntent.decline);
    });

    test('bridge words rescue a Hinglish emergency', () {
      // The embedding cannot read romanised Hindi. Without this floor a real
      // Hinglish emergency scoring 0.20 would be turned away — the worst
      // error this router can make.
      expect(
        QueryRouter.route('saanp ne kaata', confidence: 0.20).intent,
        QueryIntent.answer,
      );
      expect(
        QueryRouter.route('how do I lose weight', confidence: 0.20).intent,
        QueryIntent.decline,
      );
    });

    test('an absent embedder never declines', () {
      // Null is unknown, not zero. Refusing on evidence we do not have would
      // turn away every emergency on a build without the embedder.
      expect(
        QueryRouter.route('snake bite', confidence: null).intent,
        QueryIntent.answer,
      );
      expect(
        QueryRouter.route('snake bite', confidence: 0.0).intent,
        QueryIntent.decline,
      );
    });

    test('thresholds are ordered', () {
      expect(
        QueryRouter.capabilityVeto,
        greaterThan(QueryRouter.answerThreshold),
      );
    });
  });

  group('QueryRouter.hasBridgeTerms', () {
    test('aag is recognised despite appearing in the guides', () {
      // Regression: inferring the set as "keys the corpus never uses" missed
      // aag, which came within 0.003 of being declined.
      expect(QueryRouter.hasBridgeTerms('aag'), isTrue);
      expect(QueryRouter.hasBridgeTerms('aag lag gayi hai'), isTrue);
    });

    test('English queries carry no bridge terms', () {
      expect(QueryRouter.hasBridgeTerms('snake bite'), isFalse);
      expect(QueryRouter.hasBridgeTerms('how do I lose weight'), isFalse);
    });
  });

  group('AppResponses', () {
    test('a refusal still names what the app can do', () {
      // Stopping at "no" fails someone about to face something it can help
      // with.
      final text = AppResponses.decline();
      expect(text, contains('112'));
      expect('- '.allMatches(text).length, greaterThanOrEqualTo(5));
    });

    test('the capability answer invites the emergency', () {
      final text = AppResponses.capability();
      expect(text, contains('Survive AI'));
      expect(text, contains('Hinglish'));
      expect(text.trimRight(), endsWith('**'));
    });

    test('appended warnings are phrased as the guides phrase them', () {
      final footer = AppResponses.warningFooter(['apply a tourniquet']);
      expect(footer, contains('Do not apply a tourniquet'));
      expect(AppResponses.warningFooter([]), isEmpty);
    });
  });
}
