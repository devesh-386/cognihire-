import 'package:cognihire/core/ml/binary_metrics.dart';
import 'package:cognihire/core/ml/grouped_split.dart';
import 'package:cognihire/core/ml/sufficiency_model.dart';
import 'package:cognihire/core/ml/synthetic_sufficiency_dataset.dart';
import 'package:flutter_test/flutter_test.dart';

/// End-to-end proof that the Phase 3.2/3.3 pipeline runs and produces honest,
/// good numbers on data whose answer we know — generate -> grouped split ->
/// fit on train -> evaluate on held-out test. This is the "the product works"
/// integration test; it is still entirely synthetic and makes no claim about a
/// real candidate.
void main() {
  const gen = SyntheticSufficiencyGenerator();

  test('trained on train, evaluated on a leakage-free test split, the model '
      'discriminates well and is reasonably calibrated', () {
    final ds = gen.generate(count: 6000, seed: 100, groupCount: 300);

    final split = GroupedSplit.split(
      ds.examples,
      trainFraction: 0.7,
      seed: 100,
      groupOf: (e) => e.group,
    );

    // No candidate crosses the split — the metric below is on genuinely unseen
    // groups.
    final trainGroups = split.train.map((e) => e.group).toSet();
    final testGroups = split.test.map((e) => e.group).toSet();
    expect(trainGroups.intersection(testGroups), isEmpty);

    final model = SufficiencyModel.fitSynthetic(ds, trainOn: split.train);

    final probs = <double>[];
    final labels = <bool>[];
    for (final ex in split.test) {
      probs.add(model.predictProbability(ex.features));
      labels.add(ex.sufficient);
    }

    final metrics = BinaryMetrics.evaluate(probs, labels, calibrationBins: 10);

    // Discrimination: the Bayes-optimal AUC on this noisy generative process is
    // well below 1.0, but a correct fit should clear a clear bar.
    expect(metrics.auc, isNotNull);
    expect(metrics.auc!, greaterThan(0.7));

    // Calibration: because the model family matches the generative process, the
    // recovered probabilities should track observed frequencies closely.
    expect(metrics.expectedCalibrationError, lessThan(0.1));

    // Proper scores sane.
    expect(metrics.brier, lessThan(0.25)); // beats the 0.25 all-0.5 baseline
    expect(metrics.logLoss.isFinite, isTrue);
  });

  test('the pipeline is fully deterministic end to end', () {
    BinaryMetrics run() {
      final ds = gen.generate(count: 2000, seed: 7, groupCount: 100);
      final split = GroupedSplit.split(ds.examples,
          trainFraction: 0.7, seed: 7, groupOf: (e) => e.group);
      final model = SufficiencyModel.fitSynthetic(ds, trainOn: split.train);
      final probs = [
        for (final e in split.test) model.predictProbability(e.features)
      ];
      final labels = [for (final e in split.test) e.sufficient];
      return BinaryMetrics.evaluate(probs, labels);
    }

    final a = run();
    final b = run();
    expect(a.auc, equals(b.auc));
    expect(a.brier, equals(b.brier));
    expect(a.expectedCalibrationError, equals(b.expectedCalibrationError));
  });
}
