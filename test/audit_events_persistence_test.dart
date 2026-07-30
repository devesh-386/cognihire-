import 'package:cognihire/core/claims/claim.dart';
import 'package:cognihire/core/claims/claim_audit.dart';
import 'package:cognihire/core/persistence/json_codec.dart';
import 'package:cognihire/core/session/session_event_log.dart';
import 'package:cognihire/core/verification/verification_result.dart';
import 'package:cognihire/features/interview/interview_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final t0 = DateTime(2026, 7, 28, 8, 0, 0);

  ClaimAudit auditWithEvents() {
    final log = SessionEventLog()
      ..append(SessionEventKind.sessionStarted, at: t0, payload: {'claimCount': 1})
      ..append(SessionEventKind.claimOpened,
          at: t0.add(const Duration(seconds: 1)), payload: {'claimId': 'c1'})
      ..append(SessionEventKind.sessionEnded,
          at: t0.add(const Duration(minutes: 2)));

    return const ClaimAuditBuilder().build(
      claims: const [Claim(id: 'c1', text: 'Did a thing', source: 'resume')],
      evidenceByClaimId: const {},
      reviewerAssessments: const {},
      identityAttempts: const [],
      sessionStart: t0,
      sessionEnd: t0.add(const Duration(minutes: 2)),
      sessionEventsJsonl: log.toJsonl(),
    );
  }

  group('the session event log persists with the audit', () {
    test('round-trips through JSON and the chain still verifies', () {
      final restored = auditFromJson(auditToJson(auditWithEvents()));
      final log = SessionEventLog.fromJsonl(restored.sessionEventsJsonl);
      expect(log.entries.length, 3);
      expect(log.verifyIntegrity(), const IntegrityOk());
    });

    test('an audit with no events round-trips as an empty log', () {
      final audit = const ClaimAuditBuilder().build(
        claims: const [],
        evidenceByClaimId: const {},
        reviewerAssessments: const {},
        identityAttempts: const [],
        sessionStart: t0,
        sessionEnd: t0,
      );
      final restored = auditFromJson(auditToJson(audit));
      expect(restored.sessionEventsJsonl, '');
      expect(
          SessionEventLog.fromJsonl(restored.sessionEventsJsonl).entries, isEmpty);
    });
  });

  group('tamper-evidence is enforced at the persistence boundary', () {
    test('a stored audit whose event log was edited refuses to load', () {
      final json = auditToJson(auditWithEvents());
      // Someone edits the persisted events to erase the sessionEnded record's
      // claim linkage without recomputing hashes.
      json['sessionEvents'] =
          (json['sessionEvents'] as String).replaceFirst('"c1"', '"c2"');
      expect(() => auditFromJson(json), throwsA(isA<FormatException>()));
    });

    test('a well-formed intact log loads without complaint', () {
      // Guards against the check being too eager and rejecting valid data.
      expect(() => auditFromJson(auditToJson(auditWithEvents())), returnsNormally);
    });
  });

  group('the controller feeds its own log into the audit', () {
    test('buildAudit carries the events that actually happened', () {
      final c = InterviewController(
        claims: const [Claim(id: 'c1', text: 'x', source: 'resume')],
        startedAt: t0,
      );
      c.recordIdentityAttempt(Verified(similarity: 91, at: t0.add(const Duration(seconds: 2))));
      c.end(at: t0.add(const Duration(minutes: 1)));

      final audit = c.buildAudit();
      final log = SessionEventLog.fromJsonl(audit.sessionEventsJsonl);
      expect(log.verifyIntegrity(), const IntegrityOk());
      expect(
        log.entries.map((e) => e.kind),
        containsAll([
          SessionEventKind.sessionStarted,
          SessionEventKind.identityChecked,
          SessionEventKind.sessionEnded,
        ]),
      );
    });
  });
}
