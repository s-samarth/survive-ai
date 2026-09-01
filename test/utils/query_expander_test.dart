import 'package:flutter_test/flutter_test.dart';
import 'package:survive_ai/utils/query_expander.dart';

void main() {
  group('QueryExpander', () {
    test('bridges English survival vocabulary', () {
      final out = QueryExpander.expand('my leg is bleeding');
      expect(out, startsWith('my leg is bleeding'));
      expect(out, contains('tourniquet'));
      expect(out, contains('pressure'));
    });

    test('maps romanised Hindi onto the corpus vocabulary', () {
      // The corpus is in English; a panicking user is not. Without this, a
      // Hinglish query retrieves nothing at all.
      expect(
        QueryExpander.expand('khoon bahut nikal raha hai'),
        contains('bleeding'),
      );
      expect(QueryExpander.expand('ghar me aag lag gayi'), contains('smoke'));
      expect(QueryExpander.expand('saanp ne kaata'), contains('antivenom'));
      expect(QueryExpander.expand('bhookamp aaya hai'), contains('aftershock'));
      expect(
        QueryExpander.expand('baad ka paani ghus gaya'),
        contains('flood'),
      );
    });

    test('handles India-specific nouns', () {
      expect(
        QueryExpander.expand('lpg cylinder leaking'),
        contains('regulator'),
      );
      expect(QueryExpander.expand('teargas in my eyes'), contains('upwind'));
      expect(QueryExpander.expand('stampede at the temple'), contains('crush'));
    });

    test('stems common suffixes', () {
      expect(
        QueryExpander.expand('the building is collapsing'),
        contains('rubble'),
      );
    });

    test('does not repeat words already in the query', () {
      final out = QueryExpander.expand('bleeding wound pressure');
      final counts = <String, int>{};
      for (final w in out.split(' ')) {
        counts[w] = (counts[w] ?? 0) + 1;
      }
      expect(counts['wound'], 1);
      expect(counts['pressure'], 1);
    });

    test('returns the query unchanged when nothing matches', () {
      const q = 'zzzz qqqq';
      expect(QueryExpander.expand(q), q);
    });

    test('caps expansion so the query is not diluted', () {
      final out = QueryExpander.expand('fire smoke water blood snake gas heat');
      final added = out.split(' ').length - 7;
      expect(added, lessThanOrEqualTo(10));
    });
  });
}
