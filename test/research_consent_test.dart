import 'package:cognihire/core/claims/claim.dart';
import 'package:cognihire/core/session/session_event_log.dart';
import 'package:cognihire/features/interview/interview_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final t0 = DateTime(2026, 7, 30, 9, 0, 0);

  List<Claim> oneClaim() => const [
        Claim(id: 'c1', text: 'Built a thing', source: 'resume'),
      ];

  group('research release consent — an explicit, logged, opt-in choice', () {
    test('a session with no consent argument logs nothing about consent', () {
      final c = InterviewController(claims: oneClaim(), startedAt: t0);
      final consentEvents = c.eventLog.entries
          .where((e) => e.kind == SessionEventKind.researchConsentSet);
      expect(consentEvents, isEmpty);
    });

    test('passing researchConsentGranted: false logs an explicit refusal', () {
      final c = InterviewController(
        claims: oneClaim(),
        startedAt: t0,
        researchConsentGranted: false,
      );
      final e = c.eventLog.entries
          .singleWhere((e) => e.kind == SessionEventKind.researchConsentSet);
      expect(e.payload['granted'], false);
    });

    test('passing researchConsentGranted: true logs the grant, and the chain '
        'still verifies', () {
      final c = InterviewController(
        claims: oneClaim(),
        startedAt: t0,
        researchConsentGranted: true,
      );
      final e = c.eventLog.entries
          .singleWhere((e) => e.kind == SessionEventKind.researchConsentSet);
      expect(e.payload['granted'], true);
      expect(c.eventLog.verifyIntegrity(), const IntegrityOk());
    });

    test('the consent event is logged right after sessionStarted, before any '
        'claim is opened — never after data has already been collected', () {
      final c = InterviewController(
        claims: oneClaim(),
        startedAt: t0,
        researchConsentGranted: true,
      );
      final kinds = c.eventLog.entries.map((e) => e.kind).toList();
      expect(kinds.indexOf(SessionEventKind.researchConsentSet),
          kinds.indexOf(SessionEventKind.sessionStarted) + 1);
      expect(kinds.indexOf(SessionEventKind.researchConsentSet),
          lessThan(kinds.indexOf(SessionEventKind.claimOpened)));
    });
  });
}
