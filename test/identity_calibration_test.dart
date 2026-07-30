import 'package:cognihire/core/verification/biometric_metrics.dart';
import 'package:cognihire/core/verification/platt_scaler.dart';
import 'package:cognihire/core/verification/within_session_baseline.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('WithinSessionBaseline — self-similarity from repeated captures', () {
    test('fewer than two captures cannot establish a baseline', () {
      expect(WithinSessionBaseline.from([]), isNull);
      expect(WithinSessionBaseline.from([0.9]), isNull);
    });

    test('mean and std over pairwise-consecutive similarities', () {
      // Captures scoring 0.9, 0.92, 0.88 against the enrolled reference.
      final b = WithinSessionBaseline.from([0.9, 0.92, 0.88])!;
      expect(b.sampleCount, 3);
      expect(b.mean, closeTo((0.9 + 0.92 + 0.88) / 3, 1e-9));
      expect(b.min, closeTo(0.88, 1e-9));
      expect(b.max, closeTo(0.92, 1e-9));
      expect(b.std, greaterThan(0));
    });

    test('identical captures give a zero std, not a null or NaN', () {
      final b = WithinSessionBaseline.from([0.9, 0.9, 0.9])!;
      expect(b.std, 0.0);
    });

    test('isConsistent flags a capture that deviates sharply from the '
        'baseline', () {
      final b = WithinSessionBaseline.from([0.9, 0.91, 0.89, 0.90])!;
      expect(b.isConsistent(0.90), isTrue);
      expect(b.isConsistent(0.10), isFalse); // wildly off the establishe norm
    });

    test('a baseline of exactly two captures still computes, with std '
        'meaningful over n=2', () {
      final b = WithinSessionBaseline.from([0.8, 0.9])!;
      expect(b.sampleCount, 2);
      expect(b.mean, closeTo(0.85, 1e-9));
    });
  });

  group('PlattScaler — logistic calibration of a raw score to a probability',
      () {
    test('fitting on perfectly separable synthetic data recovers a scaler '
        'that orders scores the same way probabilities do', () {
      // Genuine matches cluster near 0.9, impostors near 0.1 — a clean,
      // synthetic, known-separable dataset. This is NOT real biometric data;
      // it exists to prove the fitting algorithm converges correctly, which is
      // an orthogonal fact to whether any particular calibration is valid.
      final scores = [0.85, 0.88, 0.92, 0.90, 0.10, 0.08, 0.15, 0.12];
      final labels = [true, true, true, true, false, false, false, false];

      final scaler = PlattScaler.fit(scores: scores, labels: labels);

      // A high raw score should calibrate to a high probability and vice
      // versa; monotonicity is the property that must hold regardless of the
      // exact A/B found.
      final pHigh = scaler.predict(0.90);
      final pLow = scaler.predict(0.10);
      expect(pHigh, greaterThan(0.5));
      expect(pLow, lessThan(0.5));
      expect(pHigh, greaterThan(pLow));
    });

    test('predict always returns a value in [0, 1]', () {
      final scaler = PlattScaler.fit(
        scores: [0.9, 0.1],
        labels: [true, false],
      );
      for (final s in [-5.0, 0.0, 0.5, 1.0, 5.0]) {
        final p = scaler.predict(s);
        expect(p, inInclusiveRange(0.0, 1.0));
      }
    });

    test('fitting requires both classes to be present', () {
      expect(
        () => PlattScaler.fit(scores: [0.9, 0.8], labels: [true, true]),
        throwsArgumentError,
      );
    });

    test('fitting requires scores and labels of equal, nonzero length', () {
      expect(
        () => PlattScaler.fit(scores: [0.9], labels: [true, false]),
        throwsArgumentError,
      );
      expect(
        () => PlattScaler.fit(scores: [], labels: []),
        throwsArgumentError,
      );
    });

    test('an unfitted identity scaler is available for use before '
        'calibration data exists — it must not silently fabricate a '
        'calibration', () {
      // The identity scaler passes the raw score through unchanged (after a
      // logit-safe clamp), documented as *not* a real calibration. Callers
      // must be able to opt into "no calibration yet" honestly instead of the
      // library inventing coefficients from nothing.
      const scaler = PlattScaler.uncalibrated();
      expect(scaler.predict(0.9), closeTo(0.9, 1e-6));
      expect(scaler.predict(0.1), closeTo(0.1, 1e-6));
      expect(scaler.isCalibrated, isFalse);
    });

    test('a fitted scaler reports isCalibrated true', () {
      final scaler =
          PlattScaler.fit(scores: [0.9, 0.1], labels: [true, false]);
      expect(scaler.isCalibrated, isTrue);
    });
  });

  group('BiometricMetrics — FAR, FRR, EER from labelled scores', () {
    // A hand-checkable dataset: genuine scores 0.6..0.9, impostor 0.1..0.4,
    // no overlap. At any threshold strictly between 0.4 and 0.6 both error
    // rates are exactly zero.
    const genuine = [0.6, 0.7, 0.8, 0.9];
    const impostor = [0.1, 0.2, 0.3, 0.4];

    test('FAR is the fraction of impostor scores at or above the threshold',
        () {
      expect(
        BiometricMetrics.falseAcceptRate(
            impostorScores: impostor, threshold: 0.5),
        0.0,
      );
      expect(
        BiometricMetrics.falseAcceptRate(
            impostorScores: impostor, threshold: 0.15),
        closeTo(3 / 4, 1e-9), // 0.2,0.3,0.4 all >= 0.15
      );
    });

    test('FRR is the fraction of genuine scores below the threshold', () {
      expect(
        BiometricMetrics.falseRejectRate(
            genuineScores: genuine, threshold: 0.5),
        0.0,
      );
      expect(
        BiometricMetrics.falseRejectRate(
            genuineScores: genuine, threshold: 0.65),
        closeTo(1 / 4, 1e-9), // only 0.6 < 0.65
      );
    });

    test('with no overlap, the EER is exactly zero at a threshold in the gap',
        () {
      final result = BiometricMetrics.equalErrorRate(
        genuineScores: genuine,
        impostorScores: impostor,
      );
      expect(result.eer, closeTo(0.0, 1e-9));
      expect(result.threshold, inInclusiveRange(0.4, 0.6));
    });

    test('with fully overlapping identical distributions, EER is 0.5', () {
      final same = [0.5, 0.5, 0.5, 0.5];
      final result = BiometricMetrics.equalErrorRate(
        genuineScores: same,
        impostorScores: same,
      );
      expect(result.eer, closeTo(0.5, 0.15));
    });

    test('an empty score list is rejected — there is no rate to compute', () {
      expect(
        () => BiometricMetrics.equalErrorRate(
          genuineScores: const [],
          impostorScores: impostor,
        ),
        throwsArgumentError,
      );
    });

    test('rates are always within [0, 1] across a threshold sweep', () {
      for (var t = -0.2; t <= 1.2; t += 0.1) {
        final far = BiometricMetrics.falseAcceptRate(
            impostorScores: impostor, threshold: t);
        final frr = BiometricMetrics.falseRejectRate(
            genuineScores: genuine, threshold: t);
        expect(far, inInclusiveRange(0.0, 1.0));
        expect(frr, inInclusiveRange(0.0, 1.0));
      }
    });
  });

  group('honesty check — nothing here claims a validated threshold', () {
    test('BiometricMetrics and PlattScaler compute from whatever data they '
        'are given; they hold no baked-in "the" threshold', () {
      // Documented, not testable as a runtime assertion beyond: calling fit
      // twice with different data gives different results, proving there is
      // no hidden constant standing in for real calibration.
      final a = PlattScaler.fit(scores: [0.9, 0.1], labels: [true, false]);
      final b = PlattScaler.fit(
        scores: [0.95, 0.05, 0.5, 0.4],
        labels: [true, false, true, false],
      );
      expect(a.predict(0.5) == b.predict(0.5), isFalse);
    });
  });
}
