import 'package:cognihire/core/claims/claim.dart';
import 'package:cognihire/core/claims/claim_audit.dart';
import 'package:cognihire/core/verification/verification_result.dart';
import 'package:cognihire/features/interview/interview_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final t0 = DateTime(2026, 7, 27, 15, 0);

  const claims = [
    Claim(id: 'c1', text: 'Built a React dashboard', source: 'resume'),
    Claim(id: 'c2', text: 'Tuned Postgres queries', source: 'resume'),
  ];

  InterviewController controller() =>
      InterviewController(claims: claims, startedAt: t0);

  test('starts on the first claim with telemetry ready', () {
    final c = controller();
    expect(c.currentClaim?.id, 'c1');
    expect(c.telemetryFor('c1'), isNotNull);
    expect(c.isComplete, isFalse);
  });

  test('typing records telemetry but raises no follow-ups', () {
    final c = controller();
    for (var i = 1; i <= 20; i++) {
      c.recordEdit('x' * (i * 2), at: t0.add(Duration(seconds: 10 + i)));
    }
    expect(c.followUpsFor('c1'), isEmpty);
  });

  test('a bulk insert raises a follow-up immediately', () {
    final c = controller();
    c.recordEdit('start', at: t0.add(const Duration(seconds: 15)));
    final fresh =
        c.recordEdit('x' * 400, at: t0.add(const Duration(seconds: 20)));

    expect(fresh, hasLength(1));
    expect(c.followUpsFor('c1'), hasLength(1));
    expect(fresh.first.wasAnswered, isFalse);
  });

  test('the same observation is not re-raised on later edits', () {
    final c = controller();
    c.recordEdit('start', at: t0.add(const Duration(seconds: 15)));
    c.recordEdit('x' * 400, at: t0.add(const Duration(seconds: 20)));
    final again =
        c.recordEdit('${'x' * 400}yz', at: t0.add(const Duration(seconds: 22)));

    expect(again, isEmpty);
    expect(c.followUpsFor('c1'), hasLength(1));
  });

  group('audit assembly', () {
    test('an untouched claim is reported notExamined', () {
      final c = controller()..end(at: t0.add(const Duration(minutes: 5)));
      final audit = c.buildAudit();

      expect(audit.findings.every((f) => f.status == ClaimStatus.notExamined),
          isTrue);
    });

    test('an answered claim with no probes is substantiated', () {
      final c = controller();
      c.recordEdit('a considered answer',
          at: t0.add(const Duration(seconds: 30)));
      c.end(at: t0.add(const Duration(minutes: 5)));

      final f = c.buildAudit().findings.firstWhere((f) => f.claim.id == 'c1');
      expect(f.status, ClaimStatus.substantiated);
      expect(f.evidence.any((e) => e.kind == EvidenceKind.processSignal),
          isTrue);
    });

    test('an unanswered follow-up leaves the claim notDemonstrated', () {
      final c = controller();
      c.recordEdit('start', at: t0.add(const Duration(seconds: 15)));
      c.recordEdit('x' * 400, at: t0.add(const Duration(seconds: 20)));
      c.end(at: t0.add(const Duration(minutes: 5)));

      final f = c.buildAudit().findings.firstWhere((f) => f.claim.id == 'c1');
      expect(f.status, ClaimStatus.notDemonstrated);
      expect(
        f.evidence.any((e) => e.observation.contains('No response recorded')),
        isTrue,
      );
    });

    test('answering the follow-up substantiates the claim', () {
      final c = controller();
      c.recordEdit('start', at: t0.add(const Duration(seconds: 15)));
      final fresh =
          c.recordEdit('x' * 400, at: t0.add(const Duration(seconds: 20)));
      c.answerFollowUp('c1', fresh.first, 'I wrote it as a sliding window '
          'because the input is streamed.', at: t0.add(const Duration(seconds: 60)));
      c.end(at: t0.add(const Duration(minutes: 5)));

      final f = c.buildAudit().findings.firstWhere((f) => f.claim.id == 'c1');
      expect(f.status, ClaimStatus.substantiated);
      expect(f.evidence.any((e) => e.observation.contains('Candidate responded')),
          isTrue);
    });

    test('advancing keeps earlier claims evidence intact', () {
      final c = controller();
      c.recordEdit('first answer', at: t0.add(const Duration(seconds: 20)));
      expect(c.advance(at: t0.add(const Duration(minutes: 2))), isTrue);
      expect(c.currentClaim?.id, 'c2');
      c.recordEdit('second answer', at: t0.add(const Duration(minutes: 3)));
      c.end(at: t0.add(const Duration(minutes: 5)));

      final audit = c.buildAudit();
      expect(audit.byStatus(ClaimStatus.substantiated), hasLength(2));
    });

    test('advance returns false past the last claim', () {
      final c = controller();
      expect(c.advance(), isTrue);
      expect(c.advance(), isFalse);
    });

    test('identity attempts flow into the audit, gaps included', () {
      final c = controller()
        ..recordIdentityAttempt(Verified(similarity: 96, at: t0))
        ..recordIdentityAttempt(Unchecked(
          reason: UncheckedReason.noFaceInFrame,
          at: t0.add(const Duration(minutes: 1)),
        ))
        ..recordIdentityAttempt(
            Verified(similarity: 95, at: t0.add(const Duration(minutes: 2))))
        ..end(at: t0.add(const Duration(minutes: 5)));

      final audit = c.buildAudit();
      expect(audit.identityAttempts, hasLength(3));
      expect(audit.identityChecksPerformed, 2);
      expect(audit.identityChecksUnmeasured, 1);
      expect(audit.provenanceQuality, ProvenanceQuality.solid);
    });

    test('a mismatch during the session makes provenance disputed', () {
      final c = controller()
        ..recordIdentityAttempt(Verified(similarity: 96, at: t0))
        ..recordIdentityAttempt(Mismatch(
          similarity: 51,
          strike: 1,
          strikesAllowed: 3,
          at: t0.add(const Duration(minutes: 1)),
        ))
        ..end(at: t0.add(const Duration(minutes: 5)));

      expect(c.buildAudit().provenanceQuality, ProvenanceQuality.disputed);
    });

    test('audit never claims more coverage than was measured', () {
      final c = controller()..end(at: t0.add(const Duration(minutes: 5)));
      final audit = c.buildAudit();

      expect(audit.identityCoverage, isNull);
      expect(audit.provenanceQuality, ProvenanceQuality.none);
      expect(audit.summary, contains('identity could not be verified'));
    });
  });
}
