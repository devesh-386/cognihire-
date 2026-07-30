import 'package:cognihire/core/features/feature_assembler.dart';
import 'package:cognihire/core/features/feature_registry.dart';
import 'package:cognihire/core/features/feature_vector.dart';
import 'package:cognihire/core/session/session_event_log.dart';
import 'package:cognihire/core/telemetry/keystroke_event.dart';
import 'package:cognihire/core/telemetry/process_telemetry.dart';
import 'package:cognihire/core/verification/verification_result.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final t0 = DateTime(2026, 8, 2, 9, 0, 0);
  const empty = FeatureAssembler();

  FeatureVector assembleWith(List<VerificationResult>? verifications) =>
      empty.assemble(
        keystrokes: KeystrokeLog(),
        process: ProcessTelemetry(taskStartedAt: t0).signals(),
        events: SessionEventLog(),
        verifications: verifications,
      );

  VerificationResult verified(double s, {int sec = 0}) =>
      Verified(similarity: s, at: t0.add(Duration(seconds: sec)));
  VerificationResult mismatch(double s, {int sec = 0, int strike = 1}) =>
      Mismatch(
          similarity: s,
          strike: strike,
          strikesAllowed: 3,
          at: t0.add(Duration(seconds: sec)));
  VerificationResult unchecked({int sec = 0}) => Unchecked(
      reason: UncheckedReason.noFaceInFrame, at: t0.add(Duration(seconds: sec)));

  group('identity feature specs are declared', () {
    test('every identity.* feature name is registered', () {
      for (final name in [
        'identity.checkCount',
        'identity.verifiedCount',
        'identity.mismatchCount',
        'identity.uncheckedCount',
        'identity.measuredCount',
        'identity.verifiedShareOfMeasured',
        'identity.uncheckedShareOfChecks',
        'identity.meanSimilarity',
        'identity.minSimilarity',
        'identity.maxSimilarity',
        'identity.stdSimilarity',
        'identity.similarityRange',
        'identity.maxConsecutiveMismatches',
        'identity.hadCriticalMismatchFlag',
        'identity.firstCheckVerifiedFlag',
        'identity.longestUncheckedRun',
      ]) {
        expect(FeatureRegistry.instance.contains(name), isTrue, reason: name);
      }
    });
  });

  group('when no verification list is supplied, every identity.* is null', () {
    test('absent verification history is not measured-as-zero', () {
      final v = assembleWith(null);
      for (final spec in FeatureRegistry.instance.specs) {
        if (spec.group != 'identity') continue;
        expect(v.value(spec.name), isNull, reason: spec.name);
      }
    });
  });

  group('an empty (but supplied) verification list', () {
    test('counts are a real zero; shares/stats that need data are null', () {
      final v = assembleWith(const []);
      expect(v.value('identity.checkCount'), 0.0);
      expect(v.value('identity.verifiedCount'), 0.0);
      expect(v.value('identity.mismatchCount'), 0.0);
      expect(v.value('identity.uncheckedCount'), 0.0);
      expect(v.value('identity.measuredCount'), 0.0);
      expect(v.value('identity.maxConsecutiveMismatches'), 0.0);
      expect(v.value('identity.longestUncheckedRun'), 0.0);
      expect(v.value('identity.hadCriticalMismatchFlag'), 0.0);
      // Nothing measured -> no similarity statistics, no shares.
      expect(v.value('identity.verifiedShareOfMeasured'), isNull);
      expect(v.value('identity.uncheckedShareOfChecks'), isNull);
      expect(v.value('identity.meanSimilarity'), isNull);
      expect(v.value('identity.minSimilarity'), isNull);
      expect(v.value('identity.maxSimilarity'), isNull);
      expect(v.value('identity.stdSimilarity'), isNull);
      expect(v.value('identity.similarityRange'), isNull);
      expect(v.value('identity.firstCheckVerifiedFlag'), isNull);
    });
  });

  group('a mixed verification history', () {
    late List<VerificationResult> history;
    setUp(() {
      // measured: 90, 80 verified; 40 mismatch. unchecked x2 (one run of 2).
      history = [
        verified(90, sec: 0),
        unchecked(sec: 1),
        unchecked(sec: 2),
        verified(80, sec: 3),
        mismatch(40, sec: 4, strike: 1),
      ];
    });

    test('counts partition the history', () {
      final v = assembleWith(history);
      expect(v.value('identity.checkCount'), 5.0);
      expect(v.value('identity.verifiedCount'), 2.0);
      expect(v.value('identity.mismatchCount'), 1.0);
      expect(v.value('identity.uncheckedCount'), 2.0);
      expect(v.value('identity.measuredCount'), 3.0);
    });

    test('shares use the right denominators', () {
      final v = assembleWith(history);
      expect(v.value('identity.verifiedShareOfMeasured'), closeTo(2 / 3, 1e-9));
      expect(v.value('identity.uncheckedShareOfChecks'), closeTo(2 / 5, 1e-9));
    });

    test('similarity statistics run over measured attempts only', () {
      final v = assembleWith(history);
      // measured similarities: 90, 80, 40. mean 70, min 40, max 90, range 50.
      expect(v.value('identity.meanSimilarity'), closeTo(70.0, 1e-9));
      expect(v.value('identity.minSimilarity'), 40.0);
      expect(v.value('identity.maxSimilarity'), 90.0);
      expect(v.value('identity.similarityRange'), 50.0);
      // population std of [90,80,40]: mean 70, var = (400+100+900)/3 = 466.667
      expect(v.value('identity.stdSimilarity'),
          closeTo(21.602468994692867, 1e-9));
    });

    test('first measured check verified, unchecked run of two', () {
      final v = assembleWith(history);
      expect(v.value('identity.firstCheckVerifiedFlag'), 1.0);
      expect(v.value('identity.longestUncheckedRun'), 2.0);
      expect(v.value('identity.maxConsecutiveMismatches'), 1.0);
      expect(v.value('identity.hadCriticalMismatchFlag'), 0.0);
    });
  });

  group('consecutive mismatch runs and criticality', () {
    test('longest run counts consecutive Mismatch entries; critical flag set',
        () {
      final history = [
        Mismatch(similarity: 30, strike: 1, strikesAllowed: 3, at: t0),
        Mismatch(
            similarity: 25,
            strike: 2,
            strikesAllowed: 3,
            at: t0.add(const Duration(seconds: 1))),
        Mismatch(
            similarity: 20,
            strike: 3,
            strikesAllowed: 3,
            at: t0.add(const Duration(seconds: 2))),
        Verified(similarity: 88, at: t0.add(const Duration(seconds: 3))),
        Mismatch(
            similarity: 22,
            strike: 1,
            strikesAllowed: 3,
            at: t0.add(const Duration(seconds: 4))),
      ];
      final v = assembleWith(history);
      expect(v.value('identity.maxConsecutiveMismatches'), 3.0);
      // strike 3 of 3 -> critical.
      expect(v.value('identity.hadCriticalMismatchFlag'), 1.0);
      expect(v.value('identity.firstCheckVerifiedFlag'), 0.0);
    });

    test('first measured check flag is null when nothing measured', () {
      final v = assembleWith([unchecked(sec: 0), unchecked(sec: 1)]);
      expect(v.value('identity.firstCheckVerifiedFlag'), isNull);
      expect(v.value('identity.longestUncheckedRun'), 2.0);
      expect(v.value('identity.measuredCount'), 0.0);
    });
  });

  group('full coverage check', () {
    test('non-nullable specs never null, with and without verifications', () {
      for (final history in [
        null,
        const <VerificationResult>[],
        [verified(90), mismatch(30)],
      ]) {
        final v = assembleWith(history);
        for (final entry in v.values.entries) {
          final spec = FeatureRegistry.instance.spec(entry.key);
          if (!spec.nullable) {
            expect(entry.value, isNotNull,
                reason: '${entry.key} must not be null');
          }
        }
      }
    });
  });
}
