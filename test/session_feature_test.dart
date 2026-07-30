import 'package:cognihire/core/features/feature_assembler.dart';
import 'package:cognihire/core/features/feature_registry.dart';
import 'package:cognihire/core/features/feature_vector.dart';
import 'package:cognihire/core/session/session_event_log.dart';
import 'package:cognihire/core/telemetry/keystroke_event.dart';
import 'package:cognihire/core/telemetry/process_telemetry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final t0 = DateTime(2026, 8, 2, 9, 0, 0);
  const empty = FeatureAssembler();

  FeatureVector assembleWith(SessionEventLog events) => empty.assemble(
        keystrokes: KeystrokeLog(),
        process: ProcessTelemetry(taskStartedAt: t0).signals(),
        events: events,
      );

  group('session feature specs are declared', () {
    test('every session.* feature name is registered', () {
      for (final name in [
        'session.eventCount',
        'session.distinctEventKinds',
        'session.claimOpenedCount',
        'session.claimAnsweredCount',
        'session.followUpCount',
        'session.identityCheckedCount',
        'session.integrityObservedCount',
        'session.spanMs',
        'session.meanInterEventMs',
        'session.eventsPerMinute',
        'session.answeredToOpenedRatio',
        'session.followUpsPerAnswer',
        'session.completedFlag',
      ]) {
        expect(FeatureRegistry.instance.contains(name), isTrue, reason: name);
      }
    });
  });

  group('an empty log', () {
    test('counts are a real zero; span/rate/ratio needing data are null', () {
      final v = assembleWith(SessionEventLog());
      expect(v.value('session.eventCount'), 0.0);
      expect(v.value('session.distinctEventKinds'), 0.0);
      expect(v.value('session.claimOpenedCount'), 0.0);
      expect(v.value('session.claimAnsweredCount'), 0.0);
      expect(v.value('session.followUpCount'), 0.0);
      expect(v.value('session.identityCheckedCount'), 0.0);
      expect(v.value('session.integrityObservedCount'), 0.0);
      expect(v.value('session.completedFlag'), 0.0);
      expect(v.value('session.spanMs'), isNull); // needs >= 2 events
      expect(v.value('session.meanInterEventMs'), isNull);
      expect(v.value('session.eventsPerMinute'), isNull);
      expect(v.value('session.answeredToOpenedRatio'), isNull); // no opens
      expect(v.value('session.followUpsPerAnswer'), isNull); // no answers
    });
  });

  group('a realistic session', () {
    late SessionEventLog log;
    setUp(() {
      log = SessionEventLog()
        ..append(SessionEventKind.sessionStarted, at: t0)
        ..append(SessionEventKind.claimOpened,
            at: t0.add(const Duration(seconds: 10)))
        ..append(SessionEventKind.identityChecked,
            at: t0.add(const Duration(seconds: 20)))
        ..append(SessionEventKind.claimAnswered,
            at: t0.add(const Duration(seconds: 40)))
        ..append(SessionEventKind.followUpAsked,
            at: t0.add(const Duration(seconds: 50)))
        ..append(SessionEventKind.followUpAsked,
            at: t0.add(const Duration(seconds: 60)))
        ..append(SessionEventKind.claimOpened,
            at: t0.add(const Duration(seconds: 70)))
        ..append(SessionEventKind.claimAnswered,
            at: t0.add(const Duration(seconds: 90)))
        ..append(SessionEventKind.sessionEnded,
            at: t0.add(const Duration(seconds: 120)));
    });

    test('per-kind counts', () {
      final v = assembleWith(log);
      expect(v.value('session.eventCount'), 9.0);
      // kinds present: started, opened, identityChecked, answered, followUp,
      // ended = 6 distinct.
      expect(v.value('session.distinctEventKinds'), 6.0);
      expect(v.value('session.claimOpenedCount'), 2.0);
      expect(v.value('session.claimAnsweredCount'), 2.0);
      expect(v.value('session.followUpCount'), 2.0);
      expect(v.value('session.identityCheckedCount'), 1.0);
      expect(v.value('session.integrityObservedCount'), 0.0);
      expect(v.value('session.completedFlag'), 1.0);
    });

    test('span, mean inter-event gap, and events-per-minute', () {
      final v = assembleWith(log);
      // first t0, last t0+120s -> span 120000ms.
      expect(v.value('session.spanMs'), 120000.0);
      // 8 gaps over 120000ms -> mean 15000ms.
      expect(v.value('session.meanInterEventMs'), closeTo(15000.0, 1e-9));
      // 9 events over 2 minutes -> 4.5 per minute.
      expect(v.value('session.eventsPerMinute'), closeTo(4.5, 1e-9));
    });

    test('answered/opened and follow-ups/answer ratios', () {
      final v = assembleWith(log);
      expect(v.value('session.answeredToOpenedRatio'), closeTo(1.0, 1e-9));
      expect(v.value('session.followUpsPerAnswer'), closeTo(1.0, 1e-9));
    });
  });

  group('a single-event log', () {
    test('span/mean/rate null (needs two points); completed flag false', () {
      final log = SessionEventLog()
        ..append(SessionEventKind.sessionStarted, at: t0);
      final v = assembleWith(log);
      expect(v.value('session.eventCount'), 1.0);
      expect(v.value('session.spanMs'), isNull);
      expect(v.value('session.meanInterEventMs'), isNull);
      expect(v.value('session.eventsPerMinute'), isNull);
      expect(v.value('session.completedFlag'), 0.0);
    });
  });

  group('full coverage check', () {
    test('non-nullable session specs are never null', () {
      for (final log in [
        SessionEventLog(),
        SessionEventLog()..append(SessionEventKind.sessionStarted, at: t0),
      ]) {
        final v = assembleWith(log);
        for (final entry in v.values.entries) {
          final spec = FeatureRegistry.instance.spec(entry.key);
          if (spec.group == 'session' && !spec.nullable) {
            expect(entry.value, isNotNull, reason: entry.key);
          }
        }
      }
    });
  });
}
