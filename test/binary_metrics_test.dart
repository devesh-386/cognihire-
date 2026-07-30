import 'dart:math' as math;

import 'package:cognihire/core/ml/binary_metrics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('input guards', () {
    test('empty input throws', () {
      expect(() => BinaryMetrics.evaluate(const [], const []),
          throwsArgumentError);
    });
    test('length mismatch throws', () {
      expect(() => BinaryMetrics.evaluate([0.5], const []), throwsArgumentError);
    });
    test('probabilities outside [0,1] throw', () {
      expect(() => BinaryMetrics.evaluate([1.5], [true]), throwsArgumentError);
    });
  });

  group('AUC', () {
    test('perfect ranking is 1.0', () {
      final m = BinaryMetrics.evaluate(
          [0.9, 0.8, 0.2, 0.1], [true, true, false, false]);
      expect(m.auc, closeTo(1.0, 1e-9));
    });
    test('reversed ranking is 0.0', () {
      final m = BinaryMetrics.evaluate(
          [0.1, 0.2, 0.8, 0.9], [true, true, false, false]);
      expect(m.auc, closeTo(0.0, 1e-9));
    });
    test('a tie across the class boundary gives 0.5 credit', () {
      // one pos, one neg, equal score -> AUC 0.5.
      final m = BinaryMetrics.evaluate([0.5, 0.5], [true, false]);
      expect(m.auc, closeTo(0.5, 1e-9));
    });
    test('is null when only one class is present (undefined, not faked)', () {
      final m = BinaryMetrics.evaluate([0.9, 0.8], [true, true]);
      expect(m.auc, isNull);
    });
  });

  group('Brier score', () {
    test('hand-computed', () {
      // (0.8-1)^2 + (0.3-0)^2 = 0.04 + 0.09 = 0.13; /2 = 0.065.
      final m = BinaryMetrics.evaluate([0.8, 0.3], [true, false]);
      expect(m.brier, closeTo(0.065, 1e-9));
    });
    test('perfect predictions give 0', () {
      final m = BinaryMetrics.evaluate([1.0, 0.0], [true, false]);
      expect(m.brier, closeTo(0.0, 1e-9));
    });
  });

  group('log loss', () {
    test('hand-computed', () {
      // -(ln(0.8) + ln(0.7)) / 2.
      final expected = -(math.log(0.8) + math.log(0.7)) / 2;
      final m = BinaryMetrics.evaluate([0.8, 0.3], [true, false]);
      expect(m.logLoss, closeTo(expected, 1e-9));
    });
    test('clamps to avoid infinity on a confident wrong prediction', () {
      final m = BinaryMetrics.evaluate([0.0], [true]);
      expect(m.logLoss.isFinite, isTrue);
    });
  });

  group('accuracy at 0.5', () {
    test('hand-computed', () {
      // 0.8->true ok, 0.3->false ok, 0.6->false wrong -> 2/3.
      final m =
          BinaryMetrics.evaluate([0.8, 0.3, 0.6], [true, false, false]);
      expect(m.accuracy, closeTo(2 / 3, 1e-9));
    });
  });

  group('expected calibration error', () {
    test('a perfectly calibrated set has near-zero ECE', () {
      // Build 100 examples: 60 at p=0.6 with 60% positives, 40 at p=0.9 with
      // 90% positives -> each bin's confidence == its accuracy.
      final probs = <double>[];
      final labels = <bool>[];
      for (var i = 0; i < 60; i++) {
        probs.add(0.6);
        labels.add(i < 36); // 36/60 = 0.6
      }
      for (var i = 0; i < 40; i++) {
        probs.add(0.9);
        labels.add(i < 36); // 36/40 = 0.9
      }
      final m = BinaryMetrics.evaluate(probs, labels, calibrationBins: 10);
      expect(m.expectedCalibrationError, closeTo(0.0, 1e-9));
    });

    test('a systematically overconfident set has high ECE', () {
      // Predict 0.95 for everything but only half are positive.
      final probs = List<double>.filled(100, 0.95);
      final labels = [for (var i = 0; i < 100; i++) i < 50];
      final m = BinaryMetrics.evaluate(probs, labels, calibrationBins: 10);
      // Confidence 0.95 vs accuracy 0.5 -> ECE ~ 0.45.
      expect(m.expectedCalibrationError, greaterThan(0.4));
    });
  });
}
