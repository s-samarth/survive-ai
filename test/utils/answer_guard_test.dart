import 'package:flutter_test/flutter_test.dart';
import 'package:survive_ai/models/doc_chunk.dart';
import 'package:survive_ai/utils/answer_guard.dart';

void main() {
  const tourniquetBody =
      'Every one of these causes harm.\n'
      '- **DO NOT apply a tourniquet.** This is the single most damaging '
      'traditional practice. Tourniquets do not stop venom spread; they cause '
      'gangrene and amputation.\n'
      '- **DO NOT suck the venom out.** It does not work.';

  final chunks = [
    const DocChunk(
      id: 'bites#p3#tourniquet',
      docId: 'bites',
      topic: 'bites',
      headingPath: 'Snakebite > What NOT To Do',
      body: tourniquetBody,
      chunkIndex: 0,
    ),
  ];

  group('AnswerGuard.forbiddenActions', () {
    test('extracts the actions the guides forbid', () {
      final actions = AnswerGuard.forbiddenActions(tourniquetBody);
      expect(actions, contains('apply a tourniquet'));
      expect(actions, contains('suck the venom out'));
    });

    test('ignores a claim about efficacy', () {
      // "Tourniquets do not stop venom spread" is not an instruction. Read as
      // one, it would forbid stopping venom spread and block correct answers.
      expect(
        AnswerGuard.forbiddenActions(tourniquetBody),
        isNot(contains('stop venom spread')),
      );
    });
  });

  group('AnswerGuard.affirms', () {
    test('tells an assertion from a warning', () {
      expect(
        AnswerGuard.affirms('Apply a tourniquet now.', 'apply a tourniquet'),
        isTrue,
      );
      expect(
        AnswerGuard.affirms('Never apply a tourniquet.', 'apply a tourniquet'),
        isFalse,
      );
      expect(
        AnswerGuard.affirms(
          'Applying a tourniquet is harmful.',
          'apply a tourniquet',
        ),
        isFalse,
      );
    });

    test('a correct answer must say the phrase to forbid it', () {
      // The reason a substring test is useless here.
      const safe = 'Do not apply a tourniquet.';
      expect(safe.toLowerCase().contains('apply a tourniquet'), isTrue);
      expect(AnswerGuard.affirms(safe, 'apply a tourniquet'), isFalse);
    });
  });

  group('AnswerGuard.check', () {
    test('blocks an answer that asserts a forbidden action', () {
      final result = AnswerGuard.check(
        'Apply a tourniquet above the bite immediately.',
        chunks,
      );

      expect(result.action, GuardAction.block);
      expect(result.violations, contains('apply a tourniquet'));
    });

    test('augments an answer that dropped a warning', () {
      // The observed conversational failure: incomplete, not wrong.
      final result = AnswerGuard.check(
        'Immobilise the limb and get to a hospital with ASV.',
        chunks,
      );

      expect(result.action, GuardAction.augment);
      expect(result.omissions, contains('apply a tourniquet'));
    });

    test('passes a correct and complete answer untouched', () {
      // A guard that fires on good answers would be worse than none.
      final result = AnswerGuard.check(
        'Do not apply a tourniquet — it causes gangrene. Do not suck the venom '
        'out. Immobilise the limb and get to a hospital with ASV.',
        chunks,
      );

      expect(result.action, GuardAction.pass);
      expect(result.violations, isEmpty);
      expect(result.omissions, isEmpty);
    });

    test('caps appended warnings so they do not bury the answer', () {
      final result = AnswerGuard.check(
        'Get to a hospital.',
        chunks,
        maxOmissions: 1,
      );
      expect(result.omissions, hasLength(1));
    });

    test('no reference material means nothing to check', () {
      // Capability answers and refusals carry no context.
      final result = AnswerGuard.check('I help with Indian emergencies.', []);
      expect(result.action, GuardAction.pass);
    });
  });
}
