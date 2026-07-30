import 'package:cognihire/core/session/session_event_log.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final t0 = DateTime(2026, 7, 28, 9, 0, 0);

  SessionEventLog buildThree() {
    final log = SessionEventLog();
    log.append(SessionEventKind.sessionStarted, at: t0, payload: {'label': 'demo'});
    log.append(SessionEventKind.claimOpened,
        at: t0.add(const Duration(seconds: 5)), payload: {'claimId': 'c1'});
    log.append(SessionEventKind.identityChecked,
        at: t0.add(const Duration(seconds: 9)), payload: {'outcome': 'verified'});
    return log;
  }

  group('append + read', () {
    test('records events in order with 1-based sequence numbers', () {
      final log = buildThree();
      expect(log.entries.length, 3);
      expect(log.entries.map((e) => e.sequence), [1, 2, 3]);
      expect(log.entries.first.kind, SessionEventKind.sessionStarted);
    });

    test('the entries view is unmodifiable', () {
      final log = buildThree();
      expect(() => log.entries.clear(), throwsUnsupportedError);
    });

    test('payload is copied on append — later mutation cannot rewrite history',
        () {
      final log = SessionEventLog();
      final payload = <String, Object?>{'claimId': 'c1'};
      log.append(SessionEventKind.claimOpened, at: t0, payload: payload);
      payload['claimId'] = 'TAMPERED';
      expect(log.entries.first.payload['claimId'], 'c1');
    });
  });

  group('hash chain — tamper evidence', () {
    test('each entry hashes the previous, so the chain is linked', () {
      final log = buildThree();
      expect(log.entries[0].previousHash, SessionEventLog.genesisHash);
      expect(log.entries[1].previousHash, log.entries[0].hash);
      expect(log.entries[2].previousHash, log.entries[1].hash);
    });

    test('the same events produce the same hashes — deterministic', () {
      expect(
        buildThree().entries.map((e) => e.hash).toList(),
        buildThree().entries.map((e) => e.hash).toList(),
      );
    });

    test('a different payload produces a different hash', () {
      final a = SessionEventLog()
        ..append(SessionEventKind.claimOpened, at: t0, payload: {'claimId': 'c1'});
      final b = SessionEventLog()
        ..append(SessionEventKind.claimOpened, at: t0, payload: {'claimId': 'c2'});
      expect(a.entries.first.hash, isNot(b.entries.first.hash));
    });

    test('a freshly built log verifies intact', () {
      expect(buildThree().verifyIntegrity(), const IntegrityOk());
    });
  });

  group('serialisation round-trip', () {
    test('survives JSONL round-trip and re-verifies', () {
      final jsonl = buildThree().toJsonl();
      final restored = SessionEventLog.fromJsonl(jsonl);
      expect(restored.entries.length, 3);
      expect(restored.verifyIntegrity(), const IntegrityOk());
      expect(restored.entries.map((e) => e.hash).toList(),
          buildThree().entries.map((e) => e.hash).toList());
    });

    test('an empty log serialises to empty and loads back empty', () {
      expect(SessionEventLog().toJsonl(), '');
      final restored = SessionEventLog.fromJsonl('');
      expect(restored.entries, isEmpty);
      expect(restored.verifyIntegrity(), const IntegrityOk());
    });
  });

  group('detecting tampering after the fact', () {
    test('a payload edited on disk fails verification at the edited entry', () {
      final jsonl = buildThree().toJsonl();
      // Swap the claim id in the second record without recomputing its hash —
      // exactly what a naive tamperer would do.
      final tampered = jsonl.replaceFirst('"c1"', '"c9"');
      final restored = SessionEventLog.fromJsonl(tampered);
      final result = restored.verifyIntegrity();
      expect(result, isA<IntegrityBroken>());
      expect((result as IntegrityBroken).firstBrokenSequence, 2);
    });

    test('deleting the genesis entry is detected', () {
      final lines = buildThree().toJsonl().split('\n');
      final withoutFirst = lines.sublist(1).join('\n');
      final restored = SessionEventLog.fromJsonl(withoutFirst);
      // The (former) second entry now claims a previousHash nothing produced.
      expect(restored.verifyIntegrity(), isA<IntegrityBroken>());
    });

    test('a corrupt record raises FormatException, never a silent skip', () {
      expect(
        () => SessionEventLog.fromJsonl('{"not":"a valid entry"}'),
        throwsFormatException,
      );
    });

    test('an unknown event kind is refused rather than defaulted', () {
      final jsonl = buildThree().toJsonl();
      final renamed = jsonl.replaceFirst('sessionStarted', 'somethingNew');
      expect(() => SessionEventLog.fromJsonl(renamed), throwsFormatException);
    });
  });
}
