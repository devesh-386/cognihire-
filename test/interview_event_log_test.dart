import 'package:cognihire/core/claims/claim.dart';
import 'package:cognihire/core/session/session_event_log.dart';
import 'package:cognihire/core/verification/verification_result.dart';
import 'package:cognihire/features/interview/interview_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final t0 = DateTime(2026, 7, 28, 10, 0, 0);

  List<Claim> twoClaims() => const [
        Claim(id: 'c1', text: 'Built a React app', source: 'resume', skill: 'React'),
        Claim(id: 'c2', text: 'Ran a Postgres migration', source: 'resume', skill: 'PostgreSQL'),
      ];

  InterviewController fresh() =>
      InterviewController(claims: twoClaims(), startedAt: t0);

  group('the controller records a session event log', () {
    test('construction logs sessionStarted then the first claimOpened', () {
      final c = fresh();
      final kinds = c.eventLog.entries.map((e) => e.kind).toList();
      expect(kinds, [
        SessionEventKind.sessionStarted,
        SessionEventKind.claimOpened,
      ]);
      expect(c.eventLog.entries[1].payload['claimId'], 'c1');
    });

    test('advancing logs a claimOpened for the next claim', () {
      final c = fresh();
      c.advance(at: t0.add(const Duration(minutes: 1)));
      final opened = c.eventLog.entries
          .where((e) => e.kind == SessionEventKind.claimOpened)
          .toList();
      expect(opened.map((e) => e.payload['claimId']), ['c1', 'c2']);
    });

    test('an identity attempt is logged by outcome, never with an embedding',
        () {
      final c = fresh();
      c.recordIdentityAttempt(
        Verified(similarity: 87.5, at: t0.add(const Duration(seconds: 30))),
      );
      final e = c.eventLog.entries.last;
      expect(e.kind, SessionEventKind.identityChecked);
      expect(e.payload['outcome'], 'verified');
      // No embedding, no vector, no face data of any kind in the log.
      expect(e.payload.keys, isNot(contains('embedding')));
    });

    test('a fresh follow-up is logged as followUpAsked', () {
      final c = fresh();
      // A large paste triggers a follow-up.
      final fresh0 = c.recordEdit('x' * 200, at: t0.add(const Duration(seconds: 5)));
      expect(fresh0, isNotEmpty);
      final asked = c.eventLog.entries
          .where((e) => e.kind == SessionEventKind.followUpAsked)
          .toList();
      expect(asked.length, fresh0.length);
    });

    test('ending the session logs sessionEnded exactly once', () {
      final c = fresh();
      c.end(at: t0.add(const Duration(minutes: 5)));
      c.end(at: t0.add(const Duration(minutes: 6))); // idempotent-ish call
      final ended = c.eventLog.entries
          .where((e) => e.kind == SessionEventKind.sessionEnded)
          .toList();
      expect(ended.length, 1);
    });
  });

  group('privacy — the log never carries answer text', () {
    test('an answer edit does not store the typed characters', () {
      final c = fresh();
      c.recordEdit('secret password hunter2', at: t0.add(const Duration(seconds: 3)));
      final serialized = c.eventLog.toJsonl();
      expect(serialized.contains('hunter2'), isFalse);
      expect(serialized.contains('secret password'), isFalse);
    });
  });

  group('integrity', () {
    test('a full session produces a verifiable, intact chain', () {
      final c = fresh();
      c.recordEdit('reducers and hooks', at: t0.add(const Duration(seconds: 4)));
      c.recordIdentityAttempt(
        Verified(similarity: 90, at: t0.add(const Duration(seconds: 10))));
      c.advance(at: t0.add(const Duration(minutes: 1)));
      c.recordEdit('a migration', at: t0.add(const Duration(minutes: 1, seconds: 5)));
      c.end(at: t0.add(const Duration(minutes: 2)));

      expect(c.eventLog.verifyIntegrity(), const IntegrityOk());
      // Round-trips and still verifies.
      final restored = SessionEventLog.fromJsonl(c.eventLog.toJsonl());
      expect(restored.verifyIntegrity(), const IntegrityOk());
    });
  });
}
