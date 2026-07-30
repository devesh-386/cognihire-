import 'package:cognihire/core/verification/capture_quality_head.dart';
import 'package:cognihire/core/verification/capture_stability_labels.dart';
import 'package:cognihire/core/verification/platt_scaler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PlattScaler.withCoefficients — an explicit, hand-set provisional '
      'calibration', () {
    test('applies the given weight/bias through the sigmoid', () {
      final scaler = PlattScaler.withCoefficients(weight: 8 / 15000, bias: -8);
      expect(scaler.predict(15000), closeTo(0.5, 1e-9)); // z = 0 at reference
      expect(scaler.predict(40000), greaterThan(0.5));
      expect(scaler.predict(5000), lessThan(0.5));
    });

    test('is reported as not-calibrated — hand-set coefficients are not a '
        'real fit', () {
      final scaler = PlattScaler.withCoefficients(weight: 1, bias: 0);
      expect(scaler.isCalibrated, isFalse);
    });
  });

  group('CaptureQualityHead.provisional — replaces the raw face-size cutoff '
      'with a soft, explainable curve centred on the same reference value',
      () {
    test('scores near 0.5 right at the reference face size', () {
      final head = CaptureQualityHead.provisional(referenceFaceSize: 15000);
      expect(head.score(15000), closeTo(0.5, 1e-6));
    });

    test('a much larger face scores high, a much smaller face scores low',
        () {
      final head = CaptureQualityHead.provisional(referenceFaceSize: 15000);
      expect(head.score(40000), greaterThan(0.9));
      expect(head.score(5000), lessThan(0.1));
    });

    test('passes() thresholds the score, defaulting to 0.5', () {
      final head = CaptureQualityHead.provisional(referenceFaceSize: 15000);
      expect(head.passes(40000), isTrue);
      expect(head.passes(5000), isFalse);
    });

    test('a provisional head reports itself as not calibrated', () {
      final head = CaptureQualityHead.provisional(referenceFaceSize: 15000);
      expect(head.isCalibrated, isFalse);
    });

    test('rejects a non-positive reference face size', () {
      expect(() => CaptureQualityHead.provisional(referenceFaceSize: 0),
          throwsArgumentError);
      expect(() => CaptureQualityHead.provisional(referenceFaceSize: -100),
          throwsArgumentError);
    });
  });

  group('CaptureQualityHead.fitted — a real Platt fit, once labelled data '
      'exists', () {
    test('reports itself as calibrated and its own coefficients drive the '
        'score', () {
      // CaptureQualityHead always normalises faceArea/referenceFaceSize
      // before handing it to the scaler, so fit() must be given data on that
      // same normalised scale (which is why the earlier PlattScaler tests use
      // small 0–1-ish values too — this is not special-cased here).
      final scaler = PlattScaler.fit(
        scores: [40000 / 15000, 38000 / 15000, 5000 / 15000, 4000 / 15000],
        labels: [true, true, false, false],
      );
      final head =
          CaptureQualityHead.fitted(scaler: scaler, referenceFaceSize: 15000);
      expect(head.isCalibrated, isTrue);
      expect(head.score(40000), greaterThan(head.score(5000)));
    });
  });

  group('selfSupervisedStabilityLabels — "good" means stable relative to '
      'nearby frames, no human annotation', () {
    List<double> v() => const [1.0, 0.0, 0.0, 0.0];
    List<double> negV() => const [-1.0, 0.0, 0.0, 0.0];

    test('an empty sequence produces no labels', () {
      expect(selfSupervisedStabilityLabels(embeddings: const []), isEmpty);
    });

    test('a single frame cannot be labelled — nothing to compare against', () {
      expect(
        selfSupervisedStabilityLabels(embeddings: [v()]),
        [null],
      );
    });

    test('with window=1, edge frames (one neighbour only) are unmeasurable; '
        'interior frames of an identical sequence are stable', () {
      final labels = selfSupervisedStabilityLabels(
        embeddings: [v(), v(), v(), v(), v()],
        window: 1,
      );
      expect(labels, [null, true, true, true, null]);
    });

    test('an outlier frame destabilises itself and both immediate neighbours '
        'under window=1', () {
      final labels = selfSupervisedStabilityLabels(
        embeddings: [v(), v(), negV(), v(), v()],
        window: 1,
      );
      expect(labels, [null, false, false, false, null]);
    });

    test('a wider window can average out a single-frame outlier for a '
        'neighbour further away', () {
      // idx3's window=2 neighbours are idx1,2,4,5 — three good, one bad —
      // mean cosine stays high enough to read as stable even though idx2 the
      // outlier itself is not.
      final labels = selfSupervisedStabilityLabels(
        embeddings: [v(), v(), negV(), v(), v(), v()],
        window: 2,
        stableThreshold: 0.4,
      );
      expect(labels[3], isTrue);
      expect(labels[2], isFalse);
    });
  });
}
