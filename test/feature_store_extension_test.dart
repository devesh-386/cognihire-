import 'package:cognihire/core/features/feature_assembler.dart';
import 'package:cognihire/core/features/feature_registry.dart';
import 'package:cognihire/core/session/session_event_log.dart';
import 'package:cognihire/core/telemetry/keystroke_event.dart';
import 'package:cognihire/core/telemetry/process_telemetry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final t0 = DateTime(2026, 7, 29, 9, 0, 0);

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

  const empty = FeatureAssembler();

  group('registry additions are properly declared', () {
    test('every new spec name is group-qualified and known to the registry',
        () {
      for (final name in [
        'typing.stdInterKeyIntervalMs',
        'typing.maxInterKeyIntervalMs',
        'typing.insertRate',
        'typing.navRate',
        'typing.alphaRate',
        'editing.bulkDeleteCount',
        'editing.longestPauseMs',
        'editing.editCount',
        'editing.totalInsertedChars',
        'editing.totalDeletedChars',
        'editing.largestBulkInsertChars',
      ]) {
        expect(FeatureRegistry.instance.contains(name), isTrue, reason: name);
      }
    });
  });

  group('typing.stdInterKeyIntervalMs', () {
    test('null with fewer than three keystrokes (fewer than two gaps)', () {
      final log = keystrokesOf([
        (0, KeycodeClass.alpha, KeystrokeAction.insert),
        (100, KeycodeClass.alpha, KeystrokeAction.insert),
      ]);
      final v = empty.assemble(
        keystrokes: log,
        process: ProcessTelemetry(taskStartedAt: t0).signals(),
        events: SessionEventLog(),
      );
      expect(v.value('typing.stdInterKeyIntervalMs'), isNull);
    });

    test('population std of the gaps, given three-plus keystrokes', () {
      // Gaps: 100, 100, 100 -> std 0.
      final log = keystrokesOf([
        (0, KeycodeClass.alpha, KeystrokeAction.insert),
        (100, KeycodeClass.alpha, KeystrokeAction.insert),
        (100, KeycodeClass.alpha, KeystrokeAction.insert),
        (100, KeycodeClass.alpha, KeystrokeAction.insert),
      ]);
      final v = empty.assemble(
        keystrokes: log,
        process: ProcessTelemetry(taskStartedAt: t0).signals(),
        events: SessionEventLog(),
      );
      expect(v.value('typing.stdInterKeyIntervalMs'), closeTo(0, 1e-9));
    });

    test('a nonzero std when gaps vary', () {
      // Gaps: 100, 300 -> mean 200, population variance ((100)^2+(100)^2)/2=10000, std=100.
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
      expect(v.value('typing.stdInterKeyIntervalMs'), closeTo(100, 1e-6));
    });
  });

  group('typing.maxInterKeyIntervalMs', () {
    test('null with fewer than two keystrokes', () {
      final log = keystrokesOf([(0, KeycodeClass.alpha, KeystrokeAction.insert)]);
      final v = empty.assemble(
        keystrokes: log,
        process: ProcessTelemetry(taskStartedAt: t0).signals(),
        events: SessionEventLog(),
      );
      expect(v.value('typing.maxInterKeyIntervalMs'), isNull);
    });

    test('the largest single gap', () {
      final log = keystrokesOf([
        (0, KeycodeClass.alpha, KeystrokeAction.insert),
        (50, KeycodeClass.alpha, KeystrokeAction.insert),
        (400, KeycodeClass.alpha, KeystrokeAction.insert),
        (20, KeycodeClass.alpha, KeystrokeAction.insert),
      ]);
      final v = empty.assemble(
        keystrokes: log,
        process: ProcessTelemetry(taskStartedAt: t0).signals(),
        events: SessionEventLog(),
      );
      expect(v.value('typing.maxInterKeyIntervalMs'), closeTo(400, 1e-9));
    });
  });

  group('typing rate features (insert/nav/alpha)', () {
    test('null when the log is empty — no keystrokes to take a rate over', () {
      final v = empty.assemble(
        keystrokes: KeystrokeLog(),
        process: ProcessTelemetry(taskStartedAt: t0).signals(),
        events: SessionEventLog(),
      );
      expect(v.value('typing.insertRate'), isNull);
      expect(v.value('typing.navRate'), isNull);
      expect(v.value('typing.alphaRate'), isNull);
    });

    test('rates are the class/action fraction of all keystrokes', () {
      final log = keystrokesOf([
        (0, KeycodeClass.alpha, KeystrokeAction.insert),
        (10, KeycodeClass.alpha, KeystrokeAction.insert),
        (10, KeycodeClass.nav, KeystrokeAction.navigate),
        (10, KeycodeClass.digit, KeystrokeAction.insert),
      ]);
      final v = empty.assemble(
        keystrokes: log,
        process: ProcessTelemetry(taskStartedAt: t0).signals(),
        events: SessionEventLog(),
      );
      expect(v.value('typing.insertRate'), closeTo(0.75, 1e-9)); // 3/4 insert
      expect(v.value('typing.navRate'), closeTo(0.25, 1e-9)); // 1/4 nav
      expect(v.value('typing.alphaRate'), closeTo(0.5, 1e-9)); // 2/4 alpha
    });
  });

  group('editing features pulled from ProcessSignals', () {
    ProcessTelemetry telemetryOf(List<int> lengthsAtSeconds) {
      final t = ProcessTelemetry(taskStartedAt: t0);
      var s = 1;
      for (final len in lengthsAtSeconds) {
        t.record(len, at: t0.add(Duration(seconds: s++)));
      }
      return t;
    }

    test('bulk delete count and edit count are never null', () {
      final v = empty.assemble(
        keystrokes: KeystrokeLog(),
        process: ProcessTelemetry(taskStartedAt: t0).signals(),
        events: SessionEventLog(),
      );
      expect(v.value('editing.bulkDeleteCount'), 0.0);
      expect(v.value('editing.editCount'), 0.0);
      expect(v.value('editing.totalInsertedChars'), 0.0);
      expect(v.value('editing.totalDeletedChars'), 0.0);
    });

    test('longestPauseMs is null with no pause and populated once one occurs',
        () {
      final noPause = telemetryOf([10, 20]);
      final vNoPause = empty.assemble(
        keystrokes: KeystrokeLog(),
        process: noPause.signals(),
        events: SessionEventLog(),
      );
      expect(vNoPause.value('editing.longestPauseMs'), isNull);

      final t = ProcessTelemetry(taskStartedAt: t0);
      t.record(10, at: t0.add(const Duration(seconds: 1)));
      t.record(20, at: t0.add(const Duration(seconds: 30))); // 29s pause
      final vPause = empty.assemble(
        keystrokes: KeystrokeLog(),
        process: t.signals(),
        events: SessionEventLog(),
      );
      expect(vPause.value('editing.longestPauseMs'), closeTo(29000, 1e-9));
    });

    test('bulk delete count, totals, and largest bulk insert reflect the '
        'underlying edits', () {
      final t = ProcessTelemetry(taskStartedAt: t0);
      t.record(200, at: t0.add(const Duration(seconds: 1))); // +200 bulk insert
      t.record(10, at: t0.add(const Duration(seconds: 2))); // -190 bulk delete
      final v = empty.assemble(
        keystrokes: KeystrokeLog(),
        process: t.signals(),
        events: SessionEventLog(),
      );
      expect(v.value('editing.bulkDeleteCount'), 1.0);
      expect(v.value('editing.totalInsertedChars'), 200.0);
      expect(v.value('editing.totalDeletedChars'), 190.0);
      expect(v.value('editing.largestBulkInsertChars'), 200.0);
      expect(v.value('editing.editCount'), 2.0);
    });
  });

  group('full coverage check', () {
    test('every emitted value is registered and non-nullable specs are never '
        'null', () {
      final log = keystrokesOf([
        (0, KeycodeClass.alpha, KeystrokeAction.insert),
        (50, KeycodeClass.digit, KeystrokeAction.insert),
        (50, KeycodeClass.delete, KeystrokeAction.delete),
      ]);
      final t = ProcessTelemetry(taskStartedAt: t0);
      t.record(50, at: t0.add(const Duration(seconds: 1)));
      final v = empty.assemble(
        keystrokes: log,
        process: t.signals(),
        events: SessionEventLog(),
      );
      for (final entry in v.values.entries) {
        final spec = FeatureRegistry.instance.spec(entry.key);
        if (!spec.nullable) {
          expect(entry.value, isNotNull, reason: '${entry.key} must not be null');
        }
      }
    });
  });
}
