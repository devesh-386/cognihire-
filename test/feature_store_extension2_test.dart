import 'package:cognihire/core/features/feature_assembler.dart';
import 'package:cognihire/core/features/feature_registry.dart';
import 'package:cognihire/core/session/session_event_log.dart';
import 'package:cognihire/core/telemetry/keystroke_event.dart';
import 'package:cognihire/core/telemetry/process_telemetry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final t0 = DateTime(2026, 7, 31, 9, 0, 0);
  const empty = FeatureAssembler();

  KeystrokeLog keystrokesOf(List<(int, KeycodeClass, KeystrokeAction)> evts) {
    final log = KeystrokeLog();
    var ms = 0;
    for (final (gap, cls, action) in evts) {
      ms += gap;
      log.add(KeystrokeEvent(
        at: t0.add(Duration(milliseconds: ms)),
        keycodeClass: cls,
        action: action,
        cursorPosition: 0,
        selectionLength: 0,
        lengthBefore: 0,
        lengthAfter: 1,
      ));
    }
    return log;
  }

  group('new specs are declared', () {
    test('every new feature name is registered', () {
      for (final name in [
        'typing.minInterKeyIntervalMs',
        'typing.medianInterKeyIntervalMs',
        'typing.digitRate',
        'typing.symbolRate',
        'typing.whitespaceRate',
        'typing.selectionRate',
        'typing.burstCount',
        'typing.longestBurstLength',
        'editing.finalAnswerLengthChars',
        'editing.hasBulkInsertFlag',
        'editing.netCharacterChange',
        'editing.bulkSpanShareOfTotal',
        'temporal.pauseRatio',
        'temporal.hasEarlyStartFlag',
      ]) {
        expect(FeatureRegistry.instance.contains(name), isTrue, reason: name);
      }
    });
  });

  group('typing.minInterKeyIntervalMs / medianInterKeyIntervalMs', () {
    test('null with fewer than two keystrokes', () {
      final log = keystrokesOf([(0, KeycodeClass.alpha, KeystrokeAction.insert)]);
      final v = empty.assemble(
        keystrokes: log,
        process: ProcessTelemetry(taskStartedAt: t0).signals(),
        events: SessionEventLog(),
      );
      expect(v.value('typing.minInterKeyIntervalMs'), isNull);
      expect(v.value('typing.medianInterKeyIntervalMs'), isNull);
    });

    test('min is the smallest gap, median is the middle value of sorted gaps',
        () {
      // Gaps: 50, 400, 100 -> sorted [50, 100, 400] -> median 100, min 50.
      final log = keystrokesOf([
        (0, KeycodeClass.alpha, KeystrokeAction.insert),
        (50, KeycodeClass.alpha, KeystrokeAction.insert),
        (400, KeycodeClass.alpha, KeystrokeAction.insert),
        (100, KeycodeClass.alpha, KeystrokeAction.insert),
      ]);
      final v = empty.assemble(
        keystrokes: log,
        process: ProcessTelemetry(taskStartedAt: t0).signals(),
        events: SessionEventLog(),
      );
      expect(v.value('typing.minInterKeyIntervalMs'), closeTo(50, 1e-9));
      expect(v.value('typing.medianInterKeyIntervalMs'), closeTo(100, 1e-9));
    });

    test('median of an even number of gaps averages the two middle values',
        () {
      // Gaps: 100, 300 -> sorted [100, 300] -> median 200.
      final log = keystrokesOf([
        (0, KeycodeClass.alpha, KeystrokeAction.insert),
        (100, KeycodeClass.alpha, KeystrokeAction.insert),
        (300, KeycodeClass.alpha, KeystrokeAction.insert),
      ]);
      final v = empty.assemble(
        keystrokes: log,
        process: ProcessTelemetry(taskStartedAt: t0).signals(),
        events: SessionEventLog(),
      );
      expect(v.value('typing.medianInterKeyIntervalMs'), closeTo(200, 1e-9));
    });
  });

  group('typing class/action rates', () {
    test('null on an empty log', () {
      final v = empty.assemble(
        keystrokes: KeystrokeLog(),
        process: ProcessTelemetry(taskStartedAt: t0).signals(),
        events: SessionEventLog(),
      );
      expect(v.value('typing.digitRate'), isNull);
      expect(v.value('typing.symbolRate'), isNull);
      expect(v.value('typing.whitespaceRate'), isNull);
      expect(v.value('typing.selectionRate'), isNull);
    });

    test('computed as class/action fraction of all keystrokes', () {
      final log = keystrokesOf([
        (0, KeycodeClass.digit, KeystrokeAction.insert),
        (10, KeycodeClass.symbol, KeystrokeAction.insert),
        (10, KeycodeClass.whitespace, KeystrokeAction.insert),
        (10, KeycodeClass.alpha, KeystrokeAction.select),
      ]);
      final v = empty.assemble(
        keystrokes: log,
        process: ProcessTelemetry(taskStartedAt: t0).signals(),
        events: SessionEventLog(),
      );
      expect(v.value('typing.digitRate'), closeTo(0.25, 1e-9));
      expect(v.value('typing.symbolRate'), closeTo(0.25, 1e-9));
      expect(v.value('typing.whitespaceRate'), closeTo(0.25, 1e-9));
      expect(v.value('typing.selectionRate'), closeTo(0.25, 1e-9));
    });
  });

  group('typing.burstCount / longestBurstLength — never null', () {
    test('zero for an empty log', () {
      final v = empty.assemble(
        keystrokes: KeystrokeLog(),
        process: ProcessTelemetry(taskStartedAt: t0).signals(),
        events: SessionEventLog(),
      );
      expect(v.value('typing.burstCount'), 0.0);
      expect(v.value('typing.longestBurstLength'), 0.0);
    });

    test('a single keystroke is one burst of length one', () {
      final log = keystrokesOf([(0, KeycodeClass.alpha, KeystrokeAction.insert)]);
      final v = empty.assemble(
        keystrokes: log,
        process: ProcessTelemetry(taskStartedAt: t0).signals(),
        events: SessionEventLog(),
      );
      expect(v.value('typing.burstCount'), 1.0);
      expect(v.value('typing.longestBurstLength'), 1.0);
    });

    test('keystrokes within the gap threshold join one burst; a gap above it '
        'starts a new burst', () {
      // Default threshold 500ms. Gaps: 100,100 (same burst), 900 (new burst),
      // 100 (same burst). -> bursts: [k0,k1,k2] length 3, [k3,k4] length 2.
      final log = keystrokesOf([
        (0, KeycodeClass.alpha, KeystrokeAction.insert),
        (100, KeycodeClass.alpha, KeystrokeAction.insert),
        (100, KeycodeClass.alpha, KeystrokeAction.insert),
        (900, KeycodeClass.alpha, KeystrokeAction.insert),
        (100, KeycodeClass.alpha, KeystrokeAction.insert),
      ]);
      final v = empty.assemble(
        keystrokes: log,
        process: ProcessTelemetry(taskStartedAt: t0).signals(),
        events: SessionEventLog(),
      );
      expect(v.value('typing.burstCount'), 2.0);
      expect(v.value('typing.longestBurstLength'), 3.0);
    });
  });

  group('editing extensions pulled from ProcessSignals', () {
    ProcessTelemetry telemetryOf(List<int> lengthsAtSeconds) {
      final t = ProcessTelemetry(taskStartedAt: t0);
      var s = 1;
      for (final len in lengthsAtSeconds) {
        t.record(len, at: t0.add(Duration(seconds: s++)));
      }
      return t;
    }

    test('finalAnswerLengthChars and netCharacterChange are never null', () {
      final v = empty.assemble(
        keystrokes: KeystrokeLog(),
        process: ProcessTelemetry(taskStartedAt: t0).signals(),
        events: SessionEventLog(),
      );
      expect(v.value('editing.finalAnswerLengthChars'), 0.0);
      expect(v.value('editing.netCharacterChange'), 0.0);
      expect(v.value('editing.hasBulkInsertFlag'), 0.0);
    });

    test('finalAnswerLengthChars matches the buffer\'s last recorded length',
        () {
      final t = telemetryOf([50, 80]);
      final v = empty.assemble(
        keystrokes: KeystrokeLog(),
        process: t.signals(),
        events: SessionEventLog(),
      );
      expect(v.value('editing.finalAnswerLengthChars'), 80.0);
    });

    test('netCharacterChange is totalInserted minus totalDeleted', () {
      final t = ProcessTelemetry(taskStartedAt: t0);
      t.record(200, at: t0.add(const Duration(seconds: 1))); // +200
      t.record(150, at: t0.add(const Duration(seconds: 2))); // -50
      final v = empty.assemble(
        keystrokes: KeystrokeLog(),
        process: t.signals(),
        events: SessionEventLog(),
      );
      expect(v.value('editing.totalInsertedChars'), 200.0);
      expect(v.value('editing.totalDeletedChars'), 50.0);
      expect(v.value('editing.netCharacterChange'), 150.0);
    });

    test('hasBulkInsertFlag is 1.0 exactly when bulkInsertCount > 0', () {
      final t = ProcessTelemetry(taskStartedAt: t0);
      t.record(200, at: t0.add(const Duration(seconds: 1))); // bulk insert
      final v = empty.assemble(
        keystrokes: KeystrokeLog(),
        process: t.signals(),
        events: SessionEventLog(),
      );
      expect(v.value('editing.hasBulkInsertFlag'), 1.0);
    });

    test('bulkSpanShareOfTotal is null when nothing was inserted, else the '
        "largest bulk insert's share of the total", () {
      final vNoInsert = empty.assemble(
        keystrokes: KeystrokeLog(),
        process: ProcessTelemetry(taskStartedAt: t0).signals(),
        events: SessionEventLog(),
      );
      expect(vNoInsert.value('editing.bulkSpanShareOfTotal'), isNull);

      final t = ProcessTelemetry(taskStartedAt: t0);
      t.record(40, at: t0.add(const Duration(seconds: 1))); // +40 typing
      t.record(240, at: t0.add(const Duration(seconds: 2))); // +200 bulk
      final v = empty.assemble(
        keystrokes: KeystrokeLog(),
        process: t.signals(),
        events: SessionEventLog(),
      );
      // totalInserted = 240, largestBulkInsert = 200 -> share = 200/240.
      expect(v.value('editing.bulkSpanShareOfTotal'), closeTo(200 / 240, 1e-9));
    });
  });

  group('temporal extensions', () {
    test('pauseRatio is null when there were no edits', () {
      final v = empty.assemble(
        keystrokes: KeystrokeLog(),
        process: ProcessTelemetry(taskStartedAt: t0).signals(),
        events: SessionEventLog(),
      );
      expect(v.value('temporal.pauseRatio'), isNull);
    });

    test('pauseRatio is pauseCount / editCount', () {
      final t = ProcessTelemetry(taskStartedAt: t0, idleGapThreshold: const Duration(seconds: 5));
      t.record(1, at: t0.add(const Duration(seconds: 1)));
      t.record(2, at: t0.add(const Duration(seconds: 10))); // 9s pause
      t.record(3, at: t0.add(const Duration(seconds: 11)));
      t.record(4, at: t0.add(const Duration(seconds: 12)));
      final v = empty.assemble(
        keystrokes: KeystrokeLog(),
        process: t.signals(),
        events: SessionEventLog(),
      );
      // 4 edits, 1 pause -> ratio 0.25.
      expect(v.value('temporal.pauseRatio'), closeTo(0.25, 1e-9));
    });

    test('hasEarlyStartFlag is null when nothing was typed (no source value '
        'to derive a flag from)', () {
      final v = empty.assemble(
        keystrokes: KeystrokeLog(),
        process: ProcessTelemetry(taskStartedAt: t0).signals(),
        events: SessionEventLog(),
      );
      expect(v.value('temporal.hasEarlyStartFlag'), isNull);
    });

    test('hasEarlyStartFlag is 1.0 under the early threshold, 0.0 at or above it',
        () {
      final early = ProcessTelemetry(taskStartedAt: t0);
      early.record(1, at: t0.add(const Duration(seconds: 1)));
      final vEarly = empty.assemble(
        keystrokes: KeystrokeLog(),
        process: early.signals(),
        events: SessionEventLog(),
      );
      expect(vEarly.value('temporal.hasEarlyStartFlag'), 1.0);

      final late = ProcessTelemetry(taskStartedAt: t0);
      late.record(1, at: t0.add(const Duration(seconds: 5)));
      final vLate = empty.assemble(
        keystrokes: KeystrokeLog(),
        process: late.signals(),
        events: SessionEventLog(),
      );
      expect(vLate.value('temporal.hasEarlyStartFlag'), 0.0);
    });
  });

  group('full coverage check', () {
    test('every emitted value is registered and non-nullable specs are never '
        'null, across a realistic mixed sample', () {
      final log = keystrokesOf([
        (0, KeycodeClass.alpha, KeystrokeAction.insert),
        (50, KeycodeClass.digit, KeystrokeAction.insert),
        (600, KeycodeClass.symbol, KeystrokeAction.insert),
        (50, KeycodeClass.delete, KeystrokeAction.delete),
        (50, KeycodeClass.whitespace, KeystrokeAction.insert),
      ]);
      final t = ProcessTelemetry(taskStartedAt: t0);
      t.record(30, at: t0.add(const Duration(seconds: 1)));
      t.record(230, at: t0.add(const Duration(seconds: 2)));
      final events = SessionEventLog()
        ..append(SessionEventKind.sessionStarted, at: t0);

      final v = empty.assemble(keystrokes: log, process: t.signals(), events: events);
      for (final entry in v.values.entries) {
        final spec = FeatureRegistry.instance.spec(entry.key);
        if (!spec.nullable) {
          expect(entry.value, isNotNull, reason: '${entry.key} must not be null');
        }
      }
    });
  });
}
