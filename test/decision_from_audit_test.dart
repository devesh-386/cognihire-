import 'package:cognihire/core/claims/claim.dart';
import 'package:cognihire/core/claims/claim_audit.dart';
import 'package:cognihire/core/graph/graph_from_audit.dart';
import 'package:cognihire/core/ml/decision_from_audit.dart';
import 'package:cognihire/core/ml/decision_guards.dart';
import 'package:cognihire/core/ml/sufficiency_model.dart';
import 'package:cognihire/core/ml/synthetic_sufficiency_dataset.dart';
import 'package:cognihire/core/verification/verification_result.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tests the bridge from a real session to the model's feature space.
///
/// The point of interest is not the arithmetic — it is that a session which
/// measured nothing produces an *absence*, not a confident zero, and that the
/// result can never be framed as a finding about a real person.
void main() {
  late SufficiencyModel model;

  setUp(() {
    model = SufficiencyModel.fitSynthetic(
      const SyntheticSufficiencyGenerator().generate(count: 300, seed: 2),
    );
  });

  ClaimAudit audit({
    List<VerificationResult> identity = const [],
    bool withEvidence = true,
  }) {
    final start = DateTime.utc(2026, 7, 30, 9);
    return const ClaimAuditBuilder().build(
      claims: const [
        Claim(id: 'c1', text: 'Built a distributed cache', source: 'Resume'),
        Claim(id: 'c2', text: 'Led a CI migration', source: 'Resume'),
      ],
      evidenceByClaimId: withEvidence
          ? {
              'c1': [
                ClaimEvidence(
                  observation: 'Asked about it. Candidate responded.',
                  kind: EvidenceKind.probeResponse,
                  at: start.add(const Duration(minutes: 1)),
                ),
              ],
            }
          : const {},
      reviewerAssessments:
          withEvidence ? const {'c1': ClaimStatus.substantiated} : const {},
      identityAttempts: identity,
      sessionStart: start,
      sessionEnd: start.add(const Duration(minutes: 10)),
      sessionEventsJsonl: '',
    );
  }

  test('a session that measured nothing yields no invented features', () {
    final a = audit(withEvidence: false);
    final inputs = auditDecisionInputs(a,
        graphs: const [], model: model);

    expect(inputs.features.containsKey('identity.verifiedShareOfMeasured'),
        isFalse,
        reason: 'no identity check happened, so there is no share to report — '
            'zero would claim every check failed');
    expect(inputs.unmeasured, isNotEmpty);
  });

  test('identity features come from what was actually measurable', () {
    final at = DateTime.utc(2026, 7, 30, 9, 5);
    final a = audit(identity: [
      Verified(similarity: 0.9, at: at),
      Mismatch(similarity: 0.2, strike: 1, strikesAllowed: 3, at: at),
      Mismatch(similarity: 0.1, strike: 2, strikesAllowed: 3, at: at),
      Unchecked(reason: UncheckedReason.noFaceInFrame, at: at),
      Verified(similarity: 0.88, at: at),
    ]);

    final inputs = auditDecisionInputs(a, graphs: const [], model: model);

    // Two verified out of four *measured* — the unchecked attempt is not
    // counted as a failure, because nothing was measured to fail.
    expect(inputs.features['identity.verifiedShareOfMeasured'], closeTo(0.5, 1e-9));
    expect(inputs.features['identity.maxConsecutiveMismatches'], 2.0,
        reason: 'the longest run, not the total');
  });

  test('graph features count real support and contradiction edges', () {
    final a = audit();
    final inputs = auditDecisionInputs(a,
        graphs: graphsFromAudit(a), model: model);

    expect(inputs.features.containsKey('graph.supportsEdgeCount'), isTrue);
    expect(inputs.features['graph.supportsEdgeCount'],
        greaterThanOrEqualTo(0.0));
  });

  test('answered-to-opened ratio reflects claims actually examined', () {
    final a = audit();
    final inputs = auditDecisionInputs(a, graphs: const [], model: model);
    // One of two claims got evidence.
    expect(inputs.features['session.answeredToOpenedRatio'], closeTo(0.5, 1e-9));
  });

  test('the decision can never be framed as being about a real person', () {
    final a = audit();
    final decision =
        buildDecisionFromAudit(a, graphs: graphsFromAudit(a), model: model);

    expect(decision.presentedAsAboutRealPerson, isFalse);
    expect(decision.committedLabelShown, isFalse);
    expect(decision.explanation.describesRealPerson, isFalse);
    expect(decision.explanation.caveat, isNotNull);
    // And therefore it passes the guards rather than being withheld.
    expect(DecisionGuards.isSafeToPresent(decision), isTrue);
  });

  test('a session where nothing was answered reports a measured zero, not an '
      'absence', () {
    // Two claims opened, none examined. That ratio is 0.0 — genuinely measured.
    // It must NOT be treated as "we did not look", which is a different fact.
    final a = audit(withEvidence: false);
    final inputs = auditDecisionInputs(a, graphs: const [], model: model);

    expect(inputs.features['session.answeredToOpenedRatio'], 0.0);
    expect(inputs.features.containsKey('session.answeredToOpenedRatio'), isTrue);

    final decision =
        buildDecisionFromAudit(a, graphs: const [], model: model);
    expect(DecisionGuards.isSafeToPresent(decision), isTrue,
        reason: 'a real measurement of zero is evidence, so the decision is '
            'presentable — with its caveat');
  });

  test('a session with no claims at all is refused by the guards', () {
    final start = DateTime.utc(2026, 7, 30, 9);
    final empty = const ClaimAuditBuilder().build(
      claims: const [],
      evidenceByClaimId: const {},
      reviewerAssessments: const {},
      identityAttempts: const [],
      sessionStart: start,
      sessionEnd: start,
      sessionEventsJsonl: '',
    );

    final decision =
        buildDecisionFromAudit(empty, graphs: const [], model: model);

    // Nothing measurable at all -> the output is the model bias alone.
    expect(DecisionGuards.isSafeToPresent(decision), isFalse);
    expect(DecisionGuards.check(decision).map((v) => v.guard),
        contains('no-evidence'));
  });

  test('unmeasured names only features the model actually knows', () {
    final a = audit();
    final inputs = auditDecisionInputs(a,
        graphs: graphsFromAudit(a), model: model);
    for (final name in inputs.unmeasured) {
      expect(model.rangeFor(name), isNotNull);
    }
  });
}
