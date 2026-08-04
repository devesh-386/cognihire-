import 'package:cognihire/core/claims/claim.dart';
import 'package:cognihire/core/interview/question_bank.dart';
import 'package:flutter_test/flutter_test.dart';

/// Phase 4.1 — the question bank, scoped to four claim types.
///
/// The design doc argued for eleven types; four is the deliberate cut, because
/// a type only earns its place if it changes what you would *ask*. These tests
/// pin the two properties that make the bank worth having: the ladder always
/// goes general -> specific -> checkable, and no question presumes the person
/// is lying.
void main() {
  const bank = QuestionBank();

  Claim claim(String text, {String? skill}) =>
      Claim(id: 'c1', text: text, source: 'resume', skill: skill);

  test('every claim type has a full ladder', () {
    for (final type in ClaimType.values) {
      for (final depth in ProbeDepth.values) {
        expect(QuestionBank.templatesFor(type, depth: depth), isNotEmpty,
            reason: '$type has no $depth question — the ladder would skip a '
                'rung and jump straight to specifics');
      }
    }
  });

  test('every template has a claim slot and fills it', () {
    final c = claim('Built a distributed cache in Go');
    for (final type in ClaimType.values) {
      for (final t in QuestionBank.templatesFor(type)) {
        expect(t.template, contains('{claim}'),
            reason: 'a template with no slot asks the same question of every '
                'claim, which is not probing anything');
        final rendered = t.render(c);
        expect(rendered, contains('Built a distributed cache in Go'));
        expect(rendered, isNot(contains('{claim}')));
      }
    }
  });

  test('no question presumes dishonesty or accuses', () {
    const banned = [
      'really',
      'actually you',
      'admit',
      'lying',
      'lie',
      'prove you',
      'if you did',
      'claim to',
      'supposedly',
      'honest',
    ];
    for (final type in ClaimType.values) {
      for (final t in QuestionBank.templatesFor(type)) {
        final lower = t.template.toLowerCase();
        for (final word in banned) {
          expect(lower, isNot(contains(word)),
              reason: 'a question that presumes guilt gets a defensive answer, '
                  'not an informative one (found "$word" in "${t.template}")');
        }
      }
    }
  });

  test('a ladder is ordered opening -> deepening -> verifying', () {
    final ladder = bank.ladderFor(
      claim('Led the payments migration'),
      ClaimType.heldRole,
      seed: 1,
    );
    expect(ladder.map((q) => q.depth),
        [ProbeDepth.opening, ProbeDepth.deepening, ProbeDepth.verifying]);
  });

  test('a ladder is deterministic for a given seed', () {
    final c = claim('Cut p99 latency by 40%');
    final a = bank.ladderFor(c, ClaimType.achievedOutcome, seed: 42);
    final b = bank.ladderFor(c, ClaimType.achievedOutcome, seed: 42);
    expect(a.map((q) => q.text), b.map((q) => q.text));
  });

  test('perDepth asks for more than one rung question when available', () {
    final ladder = bank.ladderFor(
      claim('Used Kubernetes in production'),
      ClaimType.usedTool,
      seed: 5,
      perDepth: 2,
    );
    expect(ladder.where((q) => q.depth == ProbeDepth.opening), hasLength(2));
    // Within a depth, no question repeats.
    final opening =
        ladder.where((q) => q.depth == ProbeDepth.opening).map((q) => q.text);
    expect(opening.toSet(), hasLength(opening.length));
  });

  test('perDepth beyond the available templates returns what exists, not '
      'duplicates', () {
    final ladder = bank.ladderFor(
      claim('Used Kubernetes in production'),
      ClaimType.usedTool,
      seed: 5,
      perDepth: 99,
    );
    for (final depth in ProbeDepth.values) {
      final atDepth = ladder.where((q) => q.depth == depth).toList();
      expect(atDepth, hasLength(
          QuestionBank.templatesFor(ClaimType.usedTool, depth: depth).length));
      expect(atDepth.map((q) => q.text).toSet(), hasLength(atDepth.length));
    }
  });

  test('classification returns null rather than guessing', () {
    expect(QuestionBank.classify(claim('Interested in distributed systems')),
        isNull);
    expect(QuestionBank.classify(claim('')), isNull);
  });

  test('classification recognises the four types it is scoped to', () {
    expect(QuestionBank.classify(claim('Built an internal deploy tool')),
        ClaimType.builtArtifact);
    expect(QuestionBank.classify(claim('Proficient in Rust and Postgres')),
        ClaimType.usedTool);
    expect(QuestionBank.classify(claim('Led a team of six engineers')),
        ClaimType.heldRole);
    expect(QuestionBank.classify(claim('Reduced build times by 60%')),
        ClaimType.achievedOutcome);
  });

  test('a verb ending in -led is not mistaken for leadership', () {
    // Regression. `_rules` once matched with `contains` and guarded the
    // dangerous entries with a trailing space, so 'led ' matched inside every
    // one of these and each got a full leadership question ladder — silently,
    // and about people who had led nothing. Found by running the LiveCareer
    // resume corpus through `tool/corpus_eval.dart`, where it accounted for the
    // majority of all non-null classifications.
    const notLeadership = [
      'Compiled monthly reports for the board.',
      'Handled escalated customer complaints.',
      'Scheduled staff shifts across three sites.',
      'Controlled inventory levels in the stockroom.',
      'Fulfilled orders during peak season.',
      'Settled disputes between vendors.',
      'Travelled to client sites weekly.',
      'Cancelled the vendor contract.',
    ];
    for (final text in notLeadership) {
      expect(QuestionBank.classify(claim(text)), isNot(ClaimType.heldRole),
          reason: '"$text" contains no leadership claim');
    }
  });

  test('other trailing-space guards are word-bounded too', () {
    // 'cut ' and 'used ' had the same guard and the same weakness.
    expect(QuestionBank.classify(claim('Executed the quarterly audit.')),
        isNot(ClaimType.achievedOutcome));
    expect(QuestionBank.classify(claim('Focused on client retention.')),
        isNot(ClaimType.usedTool));
    // ...and the words themselves still match, including at a sentence end.
    expect(QuestionBank.classify(claim('Cut onboarding time in half')),
        ClaimType.achievedOutcome);
    expect(QuestionBank.classify(claim('Terraform is something I have used')),
        ClaimType.usedTool);
  });

  test('classification covers the verb families real resumes use', () {
    expect(QuestionBank.classify(claim('Oversaw a team of twelve')),
        ClaimType.heldRole);
    expect(QuestionBank.classify(claim('Established the intake process')),
        ClaimType.builtArtifact);
    expect(QuestionBank.classify(claim('Utilized SAP for reconciliation')),
        ClaimType.usedTool);
    expect(QuestionBank.classify(claim('Streamlined the approval workflow')),
        ClaimType.achievedOutcome);
  });

  test('routine-duty bullets stay unclassified rather than being forced', () {
    // These dominate the LiveCareer corpus and are none of the four types. A
    // keyword added to capture them would produce a confident ladder aimed at
    // the wrong thing; null lets a reviewer route them. If this population
    // matters, the fix is a fifth claim type, not a longer list.
    const routine = [
      'Monitored balance sheet accounts.',
      'Responded to customer inquiries and complaints.',
      'Participates in weekly team meetings.',
      'Documents and tracks all member contacts.',
    ];
    for (final text in routine) {
      expect(QuestionBank.classify(claim(text)), isNull,
          reason: '"$text" is a routine duty, not one of the four types');
    }
  });

  test('classification is deterministic and order-independent of casing', () {
    final c = claim('BUILT AN INTERNAL DEPLOY TOOL');
    expect(QuestionBank.classify(c), ClaimType.builtArtifact);
    expect(QuestionBank.classify(c), QuestionBank.classify(c));
  });

  test('no two templates in the bank are identical', () {
    final all = [
      for (final type in ClaimType.values)
        for (final t in QuestionBank.templatesFor(type)) '${type.name}|${t.template}',
    ];
    expect(all.toSet(), hasLength(all.length));
  });

  test('every verifying question asks for something checkable', () {
    // The rung that earns the bank its keep: a verifying question must ask for
    // a concrete, falsifiable detail rather than another opinion.
    for (final type in ClaimType.values) {
      for (final t in QuestionBank.templatesFor(type, depth: ProbeDepth.verifying)) {
        expect(t.checkableDetail, isNotEmpty,
            reason: '${t.template} declares no checkable detail, so a reviewer '
                'has nothing to compare the answer against');
      }
    }
  });
}
