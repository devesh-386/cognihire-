import 'package:cognihire/core/telemetry/edit_event.dart';
import 'package:cognihire/core/telemetry/process_telemetry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final start = DateTime(2026, 7, 27, 10, 0, 0);

  ProcessTelemetry fresh() => ProcessTelemetry(taskStartedAt: start);

  group('classification', () {
    test('small edits are typing', () {
      final t = fresh();
      expect(t.record(5, at: start.add(const Duration(seconds: 3))).kind,
          EditKind.typing);
      expect(t.record(12, at: start.add(const Duration(seconds: 4))).kind,
          EditKind.typing);
    });

    test('a large single insertion is bulkInsert', () {
      final t = fresh();
      final e = t.record(200, at: start.add(const Duration(seconds: 5)));
      expect(e.kind, EditKind.bulkInsert);
      expect(e.delta, 200);
    });

    test('a large single deletion is bulkDelete', () {
      final t = fresh();
      t.record(200, at: start.add(const Duration(seconds: 5)));
      final e = t.record(10, at: start.add(const Duration(seconds: 6)));
      expect(e.kind, EditKind.bulkDelete);
    });
  });

  group('signals', () {
    test('empty telemetry reports nulls, not zeros', () {
      final s = fresh().signals();
      expect(s.timeToFirstKeystroke, isNull);
      expect(s.revisionRatio, isNull);
      expect(s.longestPause, isNull);
      expect(s.editCount, 0);
    });

    test('time to first keystroke measured from task start', () {
      final t = fresh();
      t.record(1, at: start.add(const Duration(seconds: 12)));
      expect(t.signals().timeToFirstKeystroke, const Duration(seconds: 12));
    });

    test('revision ratio is null when nothing was inserted', () {
      final t = fresh();
      // A deletion with no prior insertion cannot produce a ratio.
      t.record(0, at: start.add(const Duration(seconds: 2)));
      expect(t.signals().revisionRatio, isNull);
    });

    test('revision ratio reflects deleted over inserted', () {
      final t = fresh();
      t.record(100, at: start.add(const Duration(seconds: 2))); // +100
      t.record(50, at: start.add(const Duration(seconds: 3))); // -50
      final s = t.signals();
      expect(s.totalInserted, 100);
      expect(s.totalDeleted, 50);
      expect(s.revisionRatio, closeTo(0.5, 1e-9));
    });

    test('pauses counted only above the idle threshold', () {
      final t = ProcessTelemetry(
        taskStartedAt: start,
        idleGapThreshold: const Duration(seconds: 20),
      );
      t.record(1, at: start.add(const Duration(seconds: 1)));
      t.record(2, at: start.add(const Duration(seconds: 5))); // 4s, not a pause
      t.record(3, at: start.add(const Duration(seconds: 40))); // 35s pause
      t.record(4, at: start.add(const Duration(seconds: 100))); // 60s pause

      final s = t.signals();
      expect(s.pauseCount, 2);
      expect(s.longestPause, const Duration(seconds: 60));
    });

    test('tracks bulk insert count and largest span', () {
      final t = fresh();
      t.record(60, at: start.add(const Duration(seconds: 2)));
      t.record(65, at: start.add(const Duration(seconds: 3)));
      t.record(300, at: start.add(const Duration(seconds: 4)));

      final s = t.signals();
      expect(s.bulkInsertCount, 2);
      expect(s.largestBulkInsert, 235);
      expect(s.hasSpansWorthProbing, isTrue);
    });
  });

  group('spansWorthProbing', () {
    test('returns bulk insertions largest first', () {
      final t = fresh();
      t.record(60, at: start.add(const Duration(seconds: 2))); // +60
      t.record(70, at: start.add(const Duration(seconds: 3))); // +10 typing
      t.record(400, at: start.add(const Duration(seconds: 4))); // +330

      final spans = t.spansWorthProbing();
      expect(spans.length, 2);
      expect(spans.first.delta, 330);
      expect(spans.last.delta, 60);
    });

    test('typing alone produces nothing to probe', () {
      final t = fresh();
      for (var i = 1; i <= 30; i++) {
        t.record(i, at: start.add(Duration(seconds: i)));
      }
      expect(t.spansWorthProbing(), isEmpty);
      expect(t.signals().hasSpansWorthProbing, isFalse);
    });

    test('heavy revision is not treated as something to probe', () {
      // Deleting and rewriting a lot is thinking, not a flag.
      final t = fresh();
      t.record(30, at: start.add(const Duration(seconds: 2)));
      t.record(5, at: start.add(const Duration(seconds: 3)));
      t.record(35, at: start.add(const Duration(seconds: 4)));
      t.record(2, at: start.add(const Duration(seconds: 5)));

      expect(t.spansWorthProbing(), isEmpty);
      expect(t.signals().revisionRatio, greaterThan(0.5));
    });
  });
}
