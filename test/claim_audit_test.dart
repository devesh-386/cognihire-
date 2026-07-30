import 'package:cognihire/core/claims/claim.dart';
import 'package:cognihire/core/claims/claim_audit.dart';
import 'package:cognihire/core/verification/verification_result.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final start = DateTime(2026, 7, 27, 14, 0);
  final end = start.add(const Duration(minutes: 40));
  const builder = ClaimAuditBuilder();

  const claims = [
    Claim(id: 'c1', text: 'Built a React dashboard', source: 'resume p1'),
    Claim(id: 'c2', text: 'Optimised Postgres queries', source: 'resume p1'),
  ];

  ClaimEvidence ev(String text) => ClaimEvidence(
        observation: text,
        kind: EvidenceKind.probeResponse,
        at: start,
      );

  Verified verified() => Verified(similarity: 96, at: start);
  Mismatch mismatch() =>
      Mismatch(similarity: 52, strike: 1, strikesAllowed: 3, at: start);
  Unchecked unchecked() =>
      Unchecked(reason: UncheckedReason.noFaceInFrame, at: start);

  ClaimAudit audit({
    Map<String, List<ClaimEvidence>> evidence = const {},
    Map<String, ClaimStatus> assessments = const {},
    List<VerificationResult> identity = const [],
  }) =>
      builder.build(
        claims: claims,
        evidenceByClaimId: evidence,
        reviewerAssessments: assessments,
        identityAttempts: identity,
        sessionStart: start,
        sessionEnd: end,
      );

  group('claim status', () {
    test('a claim with no evidence is notExamined, never assumed', () {
      final a = audit();
      expect(a.findings.every((f) => f.status == ClaimStatus.notExamined),
          isTrue);
      expect(a.byStatus(ClaimStatus.notExamined), hasLength(2));
    });

    test('evidence without a supporting assessment is not a pass', () {
      final a = audit(evidence: {
        'c1': [ev('Explained component structure')]
      });
      // Probed but nothing says it was demonstrated → not demonstrated.
      expect(a.findings.first.status, ClaimStatus.notDemonstrated);
    });

    test('a reviewer assessment governs an examined claim', () {
      final a = audit(
        evidence: {
          'c1': [ev('Explained component structure')]
        },
        assessments: {'c1': ClaimStatus.substantiated},
      );
      expect(a.findings.first.status, ClaimStatus.substantiated);
    });

    test('an assessment cannot mark an unexamined claim as substantiated', () {
      final a = audit(assessments: {'c2': ClaimStatus.substantiated});
      final c2 = a.findings.firstWhere((f) => f.claim.id == 'c2');
      // No evidence means not examined, whatever anyone asserts about it.
      expect(c2.status, ClaimStatus.notExamined);
    });

    test('evidence is preserved for reviewer inspection', () {
      final a = audit(evidence: {
        'c1': [ev('first'), ev('second')]
      });
      expect(a.findings.first.evidence, hasLength(2));
      expect(a.findings.first.evidence.first.observation, 'first');
    });
  });

  group('provenance quality', () {
    test('no attempts at all is none, not perfect', () {
      final a = audit();
      expect(a.identityCoverage, isNull);
      expect(a.provenanceQuality, ProvenanceQuality.none);
    });

    test('all attempts unmeasured is none', () {
      final a = audit(identity: [unchecked(), unchecked()]);
      expect(a.identityChecksPerformed, 0);
      expect(a.provenanceQuality, ProvenanceQuality.none);
    });

    test('mostly unmeasured is sparse, not solid', () {
      final a = audit(identity: [
        verified(),
        unchecked(),
        unchecked(),
        unchecked(),
      ]);
      expect(a.identityCoverage, closeTo(0.25, 1e-9));
      expect(a.provenanceQuality, ProvenanceQuality.sparse);
    });

    test('any mismatch makes provenance disputed, not solid', () {
      final a = audit(identity: [verified(), verified(), mismatch()]);
      expect(a.provenanceQuality, ProvenanceQuality.disputed);
    });

    test('all checks measured and matched is solid', () {
      final a = audit(identity: [verified(), verified(), verified()]);
      expect(a.identityCoverage, 1.0);
      expect(a.provenanceQuality, ProvenanceQuality.solid);
    });
  });

  group('summary', () {
    test('states coverage and never recommends an action', () {
      final a = audit(
        evidence: {
          'c1': [ev('Explained it')]
        },
        assessments: {'c1': ClaimStatus.substantiated},
        identity: [verified(), verified()],
      );

      expect(a.summary, contains('1 of 2 claims examined'));
      expect(a.summary, contains('1 not tested'));
      expect(a.summary, contains('identity verified'));

      // The output must never read as a decision.
      final lowered = a.summary.toLowerCase();
      for (final banned in ['hire', 'reject', 'pass', 'fail', 'score', 'rank']) {
        expect(lowered, isNot(contains(banned)),
            reason: 'summary must not imply a decision ("$banned")');
      }
    });

    test('says so plainly when identity could not be verified', () {
      final a = audit(identity: [unchecked()]);
      expect(a.summary, contains('identity could not be verified'));
    });
  });
}
