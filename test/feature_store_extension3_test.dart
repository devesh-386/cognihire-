import 'package:cognihire/core/features/feature_assembler.dart';
import 'package:cognihire/core/features/feature_registry.dart';
import 'package:cognihire/core/session/session_event_log.dart';
import 'package:cognihire/core/telemetry/keystroke_event.dart';
import 'package:cognihire/core/telemetry/process_telemetry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final t0 = DateTime(2026, 8, 1, 9, 0, 0);
  const empty = FeatureAssembler();

  KeystrokeLog keystrokesOf(
    List<(int gapMs, KeycodeClass, KeystrokeAction)> evts, {
    List<int>? cursorPositions,
    List<int>? selectionLengths,
  }) {
    final log = KeystrokeLog();
    var ms = 0;
    for (var i = 0; i < evts.length; i++) {
      final (gap, cls, action) = evts[i];
      ms += gap;
      log.add(KeystrokeEvent(
        at: t0.add(Duration(milliseconds: ms)),
        keycodeClass: cls,
        action: action,
        cursorPosition: cursorPositions != null ? cursorPositions[i] : 0,
        selectionLength: selectionLengths != null ? selectionLengths[i] : 0,
        lengthBefore: 0,
        lengthAfter: 1,
      ));
    }
    return log;
  }

  group('new specs are declared', () {
    test('every new feature name is registered', () {
      for (final name in [
        'typing.modifierRate',
        'typing.cursorTravelTotal',
        'typing.meanSelectionLength',
        'typing.p90InterKeyIntervalMs',
        'typing.interKeyIntervalCV',
        'typing.veryFastKeystrokeRate',
        'editing.averageEditSizeChars',
        'editing.hasBulkDeleteFlag',
        'editing.netToGrossRatio',
        'temporal.hasLongPauseFlag',
      ]) {
        expect(FeatureRegistry.instance.contains(name), isTrue, reason: name);
      }
    });
  });

  group('typing.modifierRate', () {
    test('null on an empty log', () {
      final v = empty.assemble(
        keystrokes: KeystrokeLog(),
        process: ProcessTelemetry(taskStartedAt: t0).signals(),
        events: SessionEventLog(),
      );
      expect(v.value('typing.modifierRate'), isNull);
    });

    test('fraction of keystrokes classified as modifier', () {
      final log = keystrokesOf([
        (0, KeycodeClass.modifier, KeystrokeAction.navigate),
        (10, KeycodeClass.alpha, KeystrokeAction.insert),
        (10, KeycodeClass.alpha, KeystrokeAction.insert),
        (10, KeycodeClass.alpha, KeystrokeAction.insert),
      ]);
      final v = empty.assemble(
        keystrokes: log,
        process: ProcessTelemetry(taskStartedAt: t0).signals(),
        events: SessionEventLog(),
      );
      expect(v.value('typing.modifierRate'), closeTo(0.25, 1e-9));
    });
  });

  group('typing.cursorTravelTotal — never null', () {
    test('zero for an empty or single-event log', () {
      final v0 = empty.assemble(
        keystrokes: KeystrokeLog(),
        process: ProcessTelemetry(taskStartedAt: t0).signals(),
        events: SessionEventLog(),
      );
      expect(v0.value('typing.cursorTravelTotal'), 0.0);

      final log1 = keystrokesOf(
        [(0, KeycodeClass.alpha, KeystrokeAction.insert)],
        cursorPositions: [5],
      );
      final v1 = empty.assemble(
        keystrokes: log1,
        process: ProcessTelemetry(taskStartedAt: t0).signals(),
        events: SessionEventLog(),
      );
      expect(v1.value('typing.cursorTravelTotal'), 0.0);
    });

    test('sums the absolute cursor movement between consecutive events', () {
      // cursor: 0 -> 5 (+5) -> 2 (-3, abs 3) -> 10 (+8) => total 16.
      final log = keystrokesOf(
        [
          (0, KeycodeClass.alpha, KeystrokeAction.insert),
          (10, KeycodeClass.nav, KeystrokeAction.navigate),
          (10, KeycodeClass.nav, KeystrokeAction.navigate),
          (10, KeycodeClass.nav, KeystrokeAction.navigate),
        ],
        cursorPositions: [0, 5, 2, 10],
      );
      final v = empty.assemble(
        keystrokes: log,
        process: ProcessTelemetry(taskStartedAt: t0).signals(),
        events: SessionEventLog(),
      );
      expect(v.value('typing.cursorTravelTotal'), closeTo(16, 1e-9));
    });
  });

  group('typing.meanSelectionLength', () {
    test('null on an empty log', () {
      final v = empty.assemble(
        keystrokes: KeystrokeLog(),
        process: ProcessTelemetry(taskStartedAt: t0).signals(),
        events: SessionEventLog(),
      );
      expect(v.value('typing.meanSelectionLength'), isNull);
    });

    test('mean selectionLength across all events, including zeros', () {
      final log = keystrokesOf(
        [
          (0, KeycodeClass.alpha, KeystrokeAction.select),
          (10, KeycodeClass.alpha, KeystrokeAction.insert),
        ],
        selectionLengths: [8, 0],
      );
      final v = empty.assemble(
        keystrokes: log,
        process: ProcessTelemetry(taskStartedAt: t0).signals(),
        events: SessionEventLog(),
      );
      expect(v.value('typing.meanSelectionLength'), closeTo(4.0, 1e-9));
    });
  });

  group('typing.p90InterKeyIntervalMs', () {
    test('null with fewer than two keystrokes', () {
      final log = keystrokesOf([(0, KeycodeClass.alpha, KeystrokeAction.insert)]);
      final v = empty.assemble(
        keystrokes: log,
        process: ProcessTelemetry(taskStartedAt: t0).signals(),
        events: SessionEventLog(),
      );
      expect(v.value('typing.p90InterKeyIntervalMs'), isNull);
    });

    test('the 90th-percentile gap via nearest-rank on sorted gaps', () {
      // 11 events -> 10 gaps: nine 10ms gaps then one 1000ms gap.
      // Sorted: [10,10,10,10,10,10,10,10,10,1000].
      // Nearest-rank P90: rank = ceil(0.9*10) = 9 (1-based) -> index 8
      // (0-based) -> the 9th element, still within the run of tens -> 10.
      final evts = <(int, KeycodeClass, KeystrokeAction)>[
        (0, KeycodeClass.alpha, KeystrokeAction.insert),
      ];
      for (var i = 0; i < 9; i++) {
        evts.add((10, KeycodeClass.alpha, KeystrokeAction.insert));
      }
      evts.add((1000, KeycodeClass.alpha, KeystrokeAction.insert));
      final log = keystrokesOf(evts);
      final v = empty.assemble(
        keystrokes: log,
        process: ProcessTelemetry(taskStartedAt: t0).signals(),
        events: SessionEventLog(),
      );
      expect(v.value('typing.p90InterKeyIntervalMs'), closeTo(10, 1e-9));
    });
  });

  group('typing.interKeyIntervalCV — coefficient of variation', () {
    test('null with fewer than two gaps', () {
      final log = keystrokesOf([
        (0, KeycodeClass.alpha, KeystrokeAction.insert),
        (100, KeycodeClass.alpha, KeystrokeAction.insert),
      ]);
      final v = empty.assemble(
        keystrokes: log,
        process: ProcessTelemetry(taskStartedAt: t0).signals(),
        events: SessionEventLog(),
      );
      expect(v.value('typing.interKeyIntervalCV'), isNull);
    });

    test('is std / mean of the gaps', () {
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
      final std = v.value('typing.stdInterKeyIntervalMs')!;
      final mean = v.value('typing.meanInterKeyIntervalMs')!;
      expect(v.value('typing.interKeyIntervalCV'), closeTo(std / mean, 1e-9));
    });
  });

  group('typing.veryFastKeystrokeRate', () {
    test('null with fewer than two keystrokes', () {
      final log = keystrokesOf([(0, KeycodeClass.alpha, KeystrokeAction.insert)]);
      final v = empty.assemble(
        keystrokes: log,
        process: ProcessTelemetry(taskStartedAt: t0).signals(),
        events: SessionEventLog(),
      );
      expect(v.value('typing.veryFastKeystrokeRate'), isNull);
    });

    test('fraction of gaps under 30ms', () {
      // Gaps: 10 (<30), 50 (>=30), 20 (<30) -> 2/3.
      final log = keystrokesOf([
        (0, KeycodeClass.alpha, KeystrokeAction.insert),
        (10, KeycodeClass.alpha, KeystrokeAction.insert),
        (50, KeycodeClass.alpha, KeystrokeAction.insert),
        (20, KeycodeClass.alpha, KeystrokeAction.insert),
      ]);
      final v = empty.assemble(
        keystrokes: log,
        process: ProcessTelemetry(taskStartedAt: t0).signals(),
        events: SessionEventLog(),
      );
      expect(v.value('typing.veryFastKeystrokeRate'), closeTo(2 / 3, 1e-9));
    });
  });

  group('editing extensions', () {
    ProcessTelemetry telemetryOf(List<int> lengthsAtSeconds) {
      final t = ProcessTelemetry(taskStartedAt: t0);
      var s = 1;
      for (final len in lengthsAtSeconds) {
        t.record(len, at: t0.add(Duration(seconds: s++)));
      }
      return t;
    }

    test('averageEditSizeChars, hasBulkDeleteFlag, netToGrossRatio are null '
        '/ zero appropriately with no edits', () {
      final v = empty.assemble(
        keystrokes: KeystrokeLog(),
        process: ProcessTelemetry(taskStartedAt: t0).signals(),
        events: SessionEventLog(),
      );
      expect(v.value('editing.averageEditSizeChars'), isNull);
      expect(v.value('editing.hasBulkDeleteFlag'), 0.0);
      expect(v.value('editing.netToGrossRatio'), isNull);
    });

    test('averageEditSizeChars is (inserted+deleted)/editCount', () {
      final t = ProcessTelemetry(taskStartedAt: t0);
      t.record(100, at: t0.add(const Duration(seconds: 1))); // +100
      t.record(80, at: t0.add(const Duration(seconds: 2))); // -20
      final v = empty.assemble(
        keystrokes: KeystrokeLog(),
        process: t.signals(),
        events: SessionEventLog(),
      );
      // inserted=100, deleted=20, editCount=2 -> (100+20)/2 = 60.
      expect(v.value('editing.averageEditSizeChars'), closeTo(60, 1e-9));
    });

    test('hasBulkDeleteFlag is 1.0 exactly when bulkDeleteCount > 0', () {
      final t = telemetryOf([200, 10]); // +200 bulk insert, -190 bulk delete
      final v = empty.assemble(
        keystrokes: KeystrokeLog(),
        process: t.signals(),
        events: SessionEventLog(),
      );
      expect(v.value('editing.hasBulkDeleteFlag'), 1.0);
    });

    test('netToGrossRatio is netChange / (inserted+deleted)', () {
      final t = ProcessTelemetry(taskStartedAt: t0);
      t.record(100, at: t0.add(const Duration(seconds: 1))); // +100
      t.record(60, at: t0.add(const Duration(seconds: 2))); // -40
      final v = empty.assemble(
        keystrokes: KeystrokeLog(),
        process: t.signals(),
        events: SessionEventLog(),
      );
      // net = 100-40 = 60, gross = 100+40 = 140 -> ratio 60/140.
      expect(v.value('editing.netToGrossRatio'), closeTo(60 / 140, 1e-9));
    });
  });

  group('temporal.hasLongPauseFlag — never null', () {
    test('0.0 when no pause reached the idle threshold', () {
      final t = ProcessTelemetry(taskStartedAt: t0);
      t.record(1, at: t0.add(const Duration(seconds: 1)));
      t.record(2, at: t0.add(const Duration(seconds: 2)));
      final v = empty.assemble(
        keystrokes: KeystrokeLog(),
        process: t.signals(),
        events: SessionEventLog(),
      );
      expect(v.value('temporal.hasLongPauseFlag'), 0.0);
    });

    test('1.0 once at least one qualifying pause occurred', () {
      final t = ProcessTelemetry(taskStartedAt: t0);
      t.record(1, at: t0.add(const Duration(seconds: 1)));
      t.record(2, at: t0.add(const Duration(seconds: 30))); // 29s pause
      final v = empty.assemble(
        keystrokes: KeystrokeLog(),
        process: t.signals(),
        events: SessionEventLog(),
      );
      expect(v.value('temporal.hasLongPauseFlag'), 1.0);
    });
  });

  group('full coverage check', () {
    test('every emitted value is registered and non-nullable specs are never '
        'null, across a realistic mixed sample', () {
      final log = keystrokesOf(
        [
          (0, KeycodeClass.alpha, KeystrokeAction.insert),
          (10, KeycodeClass.modifier, KeystrokeAction.navigate),
          (600, KeycodeClass.symbol, KeystrokeAction.insert),
          (50, KeycodeClass.delete, KeystrokeAction.delete),
        ],
        cursorPositions: [0, 4, 4, 3],
        selectionLengths: [0, 2, 0, 0],
      );
      final t = ProcessTelemetry(taskStartedAt: t0);
      t.record(30, at: t0.add(const Duration(seconds: 1)));
      t.record(230, at: t0.add(const Duration(seconds: 2)));
      final v = empty.assemble(
          keystrokes: log, process: t.signals(), events: SessionEventLog());
      for (final entry in v.values.entries) {
        final spec = FeatureRegistry.instance.spec(entry.key);
        if (!spec.nullable) {
          expect(entry.value, isNotNull, reason: '${entry.key} must not be null');
        }
      }
    });
  });
}
