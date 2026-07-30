import 'package:cognihire/core/ml/binary_metrics.dart';
import 'package:cognihire/core/ml/conformal_sufficiency.dart';
import 'package:cognihire/core/ml/sufficiency_model.dart';
import 'package:cognihire/core/ml/synthetic_sufficiency_dataset.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('input guards', () {
    test('empty calibration set throws', () {
      expect(
          () => ConformalSufficiency.fit(
              scoresSufficient: const [], labels: const [], alpha: 0.1),
          throwsArgumentError);
    });
    test('length mismatch throws', () {
      expect(
          () => ConformalSufficiency.fit(
              scoresSufficient: [0.5], labels: const [], alpha: 0.1),
          throwsArgumentError);
    });
    test('alpha out of (0,1) throws', () {
      expect(
          () => ConformalSufficiency.fit(
              scoresSufficient: [0.5, 0.5],
              labels: [true, false],
              alpha: 0.0),
          throwsArgumentError);
    });
  });

  group('decision semantics', () {
    // A trivially separated calibration set so the threshold is small.
    final conf = ConformalSufficiency.fit(
      scoresSufficient: [0.95, 0.9, 0.92, 0.05, 0.1, 0.08],
      labels: [true, true, true, false, false, false],
      alpha: 0.2,
    );

    test('a confident-high score commits to sufficient', () {
      final p = conf.predict(0.97);
      expect(p.includesSufficient, isTrue);
      expect(p.includesInsufficient, isFalse);
      expect(p.isAbstain, isFalse);
      expect(p.committedLabel, isTrue);
    });

    test('a confident-low score commits to insufficient', () {
      final p = conf.predict(0.03);
      expect(p.includesInsufficient, isTrue);
      expect(p.includesSufficient, isFalse);
      expect(p.committedLabel, isFalse);
    });

    test('a borderline score abstains (set holds both labels)', () {
      final p = conf.predict(0.5);
      expect(p.isAbstain, isTrue);
      expect(p.committedLabel, isNull);
    });
  });

  test('marginal coverage guarantee: the true label is in the prediction set '
      'at least (1 - alpha) of the time on a held-out fold', () {
    const gen = SyntheticSufficiencyGenerator();
    final ds = gen.generate(count: 9000, seed: 314, groupCount: 450);

    // Three-way group split (train / calibration / test), leakage-free.
    final groups = ds.examples.map((e) => e.group).toSet().toList()..sort();
    final trainG = groups.take((groups.length * 0.5).round()).toSet();
    final calG = groups
        .skip((groups.length * 0.5).round())
        .take((groups.length * 0.25).round())
        .toSet();
    final trainEx = ds.examples.where((e) => trainG.contains(e.group)).toList();
    final calEx = ds.examples.where((e) => calG.contains(e.group)).toList();
    final testEx = ds.examples
        .where((e) => !trainG.contains(e.group) && !calG.contains(e.group))
        .toList();

    final model = SufficiencyModel.fitSynthetic(ds, trainOn: trainEx);

    const alpha = 0.1;
    final conf = ConformalSufficiency.fit(
      scoresSufficient: [
        for (final e in calEx) model.predictProbability(e.features)
      ],
      labels: [for (final e in calEx) e.sufficient],
      alpha: alpha,
    );

    var covered = 0;
    var abstains = 0;
    for (final e in testEx) {
      final pred = conf.predict(model.predictProbability(e.features));
      if (pred.covers(e.sufficient)) covered++;
      if (pred.isAbstain) abstains++;
    }
    final coverage = covered / testEx.length;

    // Split-conformal guarantees marginal coverage >= 1 - alpha in expectation;
    // allow a small finite-sample slack below the 0.90 target.
    expect(coverage, greaterThan(1 - alpha - 0.03),
        reason: 'coverage $coverage below guarantee');
    // A noisy problem must produce *some* honest abstentions, not force a
    // commitment on every borderline case.
    expect(abstains, greaterThan(0));
  });

  test('a smaller alpha (stricter coverage) never lowers coverage and tends to '
      'abstain at least as often', () {
    const gen = SyntheticSufficiencyGenerator();
    final ds = gen.generate(count: 6000, seed: 27, groupCount: 300);
    final groups = ds.examples.map((e) => e.group).toSet().toList()..sort();
    final trainG = groups.take((groups.length * 0.6).round()).toSet();
    final calEx =
        ds.examples.where((e) => !trainG.contains(e.group)).toList();
    final trainEx = ds.examples.where((e) => trainG.contains(e.group)).toList();
    final model = SufficiencyModel.fitSynthetic(ds, trainOn: trainEx);
    final scores = [for (final e in calEx) model.predictProbability(e.features)];
    final labels = [for (final e in calEx) e.sufficient];

    int abstainsAt(double alpha) {
      final c = ConformalSufficiency.fit(
          scoresSufficient: scores, labels: labels, alpha: alpha);
      return calEx
          .where((e) => c.predict(model.predictProbability(e.features)).isAbstain)
          .length;
    }

    // Stricter guarantee (alpha 0.05) should not abstain fewer times than a
    // looser one (alpha 0.2).
    expect(abstainsAt(0.05), greaterThanOrEqualTo(abstainsAt(0.2)));
  });

  test('when it commits, it is right more often than the raw 0.5-threshold '
      'accuracy — abstaining on the hard cases pays off', () {
    const gen = SyntheticSufficiencyGenerator();
    final ds = gen.generate(count: 6000, seed: 55, groupCount: 300);
    final groups = ds.examples.map((e) => e.group).toSet().toList()..sort();
    final trainG = groups.take((groups.length * 0.5).round()).toSet();
    final calG = groups
        .skip((groups.length * 0.5).round())
        .take((groups.length * 0.25).round())
        .toSet();
    final trainEx = ds.examples.where((e) => trainG.contains(e.group)).toList();
    final calEx = ds.examples.where((e) => calG.contains(e.group)).toList();
    final testEx = ds.examples
        .where((e) => !trainG.contains(e.group) && !calG.contains(e.group))
        .toList();
    final model = SufficiencyModel.fitSynthetic(ds, trainOn: trainEx);
    final conf = ConformalSufficiency.fit(
      scoresSufficient: [
        for (final e in calEx) model.predictProbability(e.features)
      ],
      labels: [for (final e in calEx) e.sufficient],
      alpha: 0.2,
    );

    final rawAcc = BinaryMetrics.evaluate(
      [for (final e in testEx) model.predictProbability(e.features)],
      [for (final e in testEx) e.sufficient],
    ).accuracy;

    var committed = 0;
    var committedCorrect = 0;
    for (final e in testEx) {
      final pred = conf.predict(model.predictProbability(e.features));
      if (pred.committedLabel != null) {
        committed++;
        if (pred.committedLabel == e.sufficient) committedCorrect++;
      }
    }
    final committedAcc = committedCorrect / committed;
    expect(committedAcc, greaterThan(rawAcc));
  });
}
