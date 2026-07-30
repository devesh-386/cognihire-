import 'package:cognihire/core/ml/sufficiency_model.dart';
import 'package:cognihire/core/ml/synthetic_sufficiency_dataset.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const gen = SyntheticSufficiencyGenerator();

  test('a model fit on synthetic data is honestly flagged as such', () {
    final ds = gen.generate(count: 500, seed: 1);
    final model = SufficiencyModel.fitSynthetic(ds);
    expect(model.trainedOnSyntheticData, isTrue);
    expect(model.isValidatedOnRealData, isFalse);
  });

  test('the trainer recovers the planted sign of every signal feature', () {
    final ds = gen.generate(count: 6000, seed: 21);
    final model = SufficiencyModel.fitSynthetic(ds);
    ds.groundTruthWeights.forEach((name, trueW) {
      final learned = model.weightFor(name);
      expect(learned, isNotNull, reason: name);
      expect(learned! * trueW, greaterThan(0),
          reason: 'sign of $name: learned $learned vs planted $trueW');
    });
  });

  test('recovered magnitudes are in the right ballpark for the strongest '
      'features', () {
    final ds = gen.generate(count: 8000, seed: 22);
    final model = SufficiencyModel.fitSynthetic(ds);
    // Not exact (finite sample, Bernoulli noise) but should be within a
    // reasonable factor of the planted weights.
    for (final name in [
      'graph.supportsEdgeCount',
      'graph.contradictsEdgeCount',
      'typing.veryFastKeystrokeRate',
    ]) {
      final learned = model.weightFor(name)!;
      final planted = ds.groundTruthWeights[name]!;
      expect(learned.abs(), greaterThan(planted.abs() * 0.4), reason: name);
      expect(learned.abs(), lessThan(planted.abs() * 2.2), reason: name);
    }
  });

  test('zero-weight noise features are learned near zero, not latched onto',
      () {
    final ds = gen.generate(count: 8000, seed: 23);
    final model = SufficiencyModel.fitSynthetic(ds);
    // These are in the vectors but carry no generative signal.
    for (final name in ['typing.backspaceRate', 'session.followUpCount']) {
      final learned = model.weightFor(name);
      expect(learned, isNotNull, reason: name);
      // Much smaller than the real signal weights (which are ~1+).
      expect(learned!.abs(), lessThan(0.35), reason: '$name learned $learned');
    }
  });

  test('predicted probability separates the classes (ranks sufficient higher)',
      () {
    final ds = gen.generate(count: 4000, seed: 24);
    final model = SufficiencyModel.fitSynthetic(ds);
    final pos = <double>[];
    final neg = <double>[];
    for (final ex in ds.examples) {
      final p = model.predictProbability(ex.features);
      (ex.sufficient ? pos : neg).add(p);
    }
    double mean(List<double> xs) => xs.reduce((a, b) => a + b) / xs.length;
    expect(mean(pos), greaterThan(mean(neg) + 0.1));
  });

  test('predictProbability always returns a valid probability', () {
    final ds = gen.generate(count: 300, seed: 25);
    final model = SufficiencyModel.fitSynthetic(ds);
    for (final ex in ds.examples) {
      expect(model.predictProbability(ex.features), inInclusiveRange(0.0, 1.0));
    }
  });

  test('fit is deterministic given the same dataset', () {
    final ds = gen.generate(count: 1000, seed: 26);
    final a = SufficiencyModel.fitSynthetic(ds);
    final b = SufficiencyModel.fitSynthetic(ds);
    expect(a.bias, closeTo(b.bias, 1e-12));
    for (final name in ds.groundTruthWeights.keys) {
      expect(a.weightFor(name), closeTo(b.weightFor(name)!, 1e-12));
    }
  });
}
