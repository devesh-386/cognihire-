import 'package:cognihire/core/ml/binary_metrics.dart';
import 'package:cognihire/core/ml/isotonic_calibrator.dart';
import 'package:cognihire/core/ml/sufficiency_model.dart';
import 'package:cognihire/core/ml/synthetic_sufficiency_dataset.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('input guards', () {
    test('empty input throws', () {
      expect(() => IsotonicCalibrator.fit(const [], const []),
          throwsArgumentError);
    });
    test('length mismatch throws', () {
      expect(() => IsotonicCalibrator.fit([0.5], const []), throwsArgumentError);
    });
  });

  group('monotonicity (PAVA output is non-decreasing)', () {
    test('a clearly separable set yields a non-decreasing mapping', () {
      final scores = [0.1, 0.2, 0.3, 0.6, 0.7, 0.8, 0.9];
      final labels = [false, false, false, true, true, true, true];
      final cal = IsotonicCalibrator.fit(scores, labels);
      var prev = -1.0;
      for (final s in [0.0, 0.15, 0.25, 0.5, 0.65, 0.85, 1.0]) {
        final c = cal.calibrate(s);
        expect(c, greaterThanOrEqualTo(prev - 1e-12), reason: 'at $s');
        expect(c, inInclusiveRange(0.0, 1.0));
        prev = c;
      }
    });
  });

  group('known-answer pooling', () {
    test('a single adjacent violation is pooled to the average', () {
      // Scores ascending; labels 0,1,0,1. PAVA pools the middle 1,0 (a
      // violation) into a block of mean 0.5, leaving three blocks with values
      // [0, 0.5, 1] spanning scores {0.1}, {0.2,0.3}, {0.4}.
      final cal = IsotonicCalibrator.fit(
          [0.1, 0.2, 0.3, 0.4], [false, true, false, true]);
      expect(cal.calibrate(0.1), closeTo(0.0, 1e-9));
      expect(cal.calibrate(0.2), closeTo(0.5, 1e-9));
      expect(cal.calibrate(0.3), closeTo(0.5, 1e-9));
      expect(cal.calibrate(0.4), closeTo(1.0, 1e-9));
    });

    test('already-monotonic data is left essentially unchanged', () {
      final cal = IsotonicCalibrator.fit(
          [0.1, 0.4, 0.6, 0.9], [false, false, true, true]);
      expect(cal.calibrate(0.1), closeTo(0.0, 1e-9));
      expect(cal.calibrate(0.9), closeTo(1.0, 1e-9));
    });
  });

  test('calibration reduces ECE on a deliberately overconfident model', () {
    const gen = SyntheticSufficiencyGenerator();
    final ds = gen.generate(count: 6000, seed: 200, groupCount: 300);

    // Three-way group split: train / calibration / test, no leakage.
    final groups = ds.examples.map((e) => e.group).toSet().toList()..sort();
    final trainG = groups.take((groups.length * 0.5).round()).toSet();
    final calG = groups
        .skip((groups.length * 0.5).round())
        .take((groups.length * 0.25).round())
        .toSet();
    final trainEx =
        ds.examples.where((e) => trainG.contains(e.group)).toList();
    final calEx = ds.examples.where((e) => calG.contains(e.group)).toList();
    final testEx = ds.examples
        .where((e) => !trainG.contains(e.group) && !calG.contains(e.group))
        .toList();

    final model = SufficiencyModel.fitSynthetic(ds, trainOn: trainEx);

    // Make it overconfident on purpose: push probabilities toward 0/1.
    double sharpen(double p) {
      final z = (p - 0.5) * 3.0 + 0.5;
      return z.clamp(0.0, 1.0);
    }

    final rawTest = [
      for (final e in testEx) sharpen(model.predictProbability(e.features))
    ];
    final testLabels = [for (final e in testEx) e.sufficient];
    final rawEce =
        BinaryMetrics.evaluate(rawTest, testLabels).expectedCalibrationError;

    // Fit the calibrator on the calibration fold's (sharpened score, label).
    final cal = IsotonicCalibrator.fit(
      [for (final e in calEx) sharpen(model.predictProbability(e.features))],
      [for (final e in calEx) e.sufficient],
    );
    final calTest = [for (final s in rawTest) cal.calibrate(s)];
    final calEce =
        BinaryMetrics.evaluate(calTest, testLabels).expectedCalibrationError;

    expect(calEce, lessThan(rawEce),
        reason: 'raw ECE $rawEce should drop after isotonic calibration '
            '(got $calEce)');
  });
}
