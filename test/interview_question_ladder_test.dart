import 'package:cognihire/core/claims/claim.dart';
import 'package:cognihire/core/interview/question_bank.dart';
import 'package:cognihire/features/interview/interview_controller.dart';
import 'package:flutter_test/flutter_test.dart';

/// The question bank wired into a live session.
///
/// The bank itself is tested in `question_bank_test.dart`; these check the
/// integration properties that only exist once a controller owns it — that a
/// ladder is stable for the life of a claim, that an unclassifiable claim gets
/// nothing rather than something generic, and that the choice is on the record.
void main() {
  InterviewController controller(List<Claim> claims) => InterviewController(
        claims: claims,
        startedAt: DateTime.utc(2026, 7, 30, 9),
      );

  test('a classifiable claim gets a full ladder at open', () {
    final c = controller(const [
      Claim(id: 'c1', text: 'Built a distributed cache in Go', source: 'Resume'),
    ]);

    final questions = c.questionsFor('c1');
    expect(c.claimTypeFor('c1'), ClaimType.builtArtifact);
    expect(questions.map((q) => q.depth),
        [ProbeDepth.opening, ProbeDepth.deepening, ProbeDepth.verifying]);
    for (final q in questions) {
      expect(q.text, contains('Built a distributed cache in Go'));
    }
  });

  test('an unclassifiable claim gets no questions, not generic ones', () {
    final c = controller(const [
      Claim(id: 'c1', text: 'Interested in distributed systems', source: 'CV'),
    ]);

    expect(c.claimTypeFor('c1'), isNull);
    expect(c.questionsFor('c1'), isEmpty,
        reason: 'a generic question shown as a targeted one is worse than none');
  });

  test('the ladder is stable across repeated reads', () {
    final c = controller(const [
      Claim(id: 'c1', text: 'Reduced p99 latency by 40%', source: 'Resume'),
    ]);

    expect(c.questionsFor('c1').map((q) => q.text),
        c.questionsFor('c1').map((q) => q.text));
  });

  test('two controllers over the same claim ask the same questions', () {
    const claims = [
      Claim(id: 'c1', text: 'Led a team of six engineers', source: 'Resume'),
    ];
    expect(controller(claims).questionsFor('c1').map((q) => q.text),
        controller(claims).questionsFor('c1').map((q) => q.text),
        reason: 'seeding must not depend on String.hashCode, which Dart does '
            'not promise is stable between processes');
  });

  test('advancing builds the next claim ladder without disturbing the first',
      () {
    final c = controller(const [
      Claim(id: 'c1', text: 'Built an internal deploy tool', source: 'Resume'),
      Claim(id: 'c2', text: 'Proficient in Rust and Postgres', source: 'Resume'),
    ]);

    final first = c.questionsFor('c1').map((q) => q.text).toList();
    expect(c.questionsFor('c2'), isEmpty, reason: 'not opened yet');

    expect(c.advance(), isTrue);
    expect(c.claimTypeFor('c2'), ClaimType.usedTool);
    expect(c.questionsFor('c2'), isNotEmpty);
    expect(c.questionsFor('c1').map((q) => q.text), first);
  });

  test('the classification is recorded in the event log, including a null', () {
    final classified = controller(const [
      Claim(id: 'c1', text: 'Built an internal deploy tool', source: 'Resume'),
    ]);
    expect(classified.eventLog.toJsonl(), contains('builtArtifact'));

    final unclassified = controller(const [
      Claim(id: 'c1', text: 'Interested in systems work', source: 'CV'),
    ]);
    // The claim still opens and is still on the record — it simply has no type.
    expect(unclassified.eventLog.toJsonl(), contains('claimOpened'));
    expect(unclassified.eventLog.toJsonl(), isNot(contains('builtArtifact')));
  });

  test('questionsFor is unmodifiable', () {
    final c = controller(const [
      Claim(id: 'c1', text: 'Built a deploy tool', source: 'Resume'),
    ]);
    expect(() => c.questionsFor('c1').clear(), throwsUnsupportedError);
  });
}
