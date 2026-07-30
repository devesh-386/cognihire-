import 'package:cognihire/core/features/feature_registry.dart';
import 'package:cognihire/core/ml/synthetic_sufficiency_dataset.dart';
import 'package:flutter_test/flutter_test.dart';

double _mean(Iterable<double> xs) {
  final l = xs.toList();
  return l.reduce((a, b) => a + b) / l.length;
}

void main() {
  const gen = SyntheticSufficiencyGenerator();

  test('is loudly, permanently marked synthetic', () {
    final ds = gen.generate(count: 10, seed: 1);
    expect(ds.isSynthetic, isTrue);
  });

  test('every feature name it emits is a real registered feature', () {
    final ds = gen.generate(count: 50, seed: 7);
    for (final ex in ds.examples) {
      for (final name in ex.features.keys) {
        expect(FeatureRegistry.instance.contains(name), isTrue, reason: name);
      }
    }
    for (final name in ds.groundTruthWeights.keys) {
      expect(FeatureRegistry.instance.contains(name), isTrue, reason: name);
    }
  });

  test('generation is deterministic for a given seed', () {
    final a = gen.generate(count: 200, seed: 42);
    final b = gen.generate(count: 200, seed: 42);
    expect(a.examples.length, b.examples.length);
    for (var i = 0; i < a.examples.length; i++) {
      expect(a.examples[i].sufficient, b.examples[i].sufficient, reason: '$i');
      expect(a.examples[i].features, b.examples[i].features, reason: '$i');
    }
  });

  test('different seeds produce different label sequences', () {
    final a = gen.generate(count: 200, seed: 1);
    final b = gen.generate(count: 200, seed: 2);
    final la = a.examples.map((e) => e.sufficient).toList();
    final lb = b.examples.map((e) => e.sufficient).toList();
    expect(la, isNot(equals(lb)));
  });

  test('both classes are present in a reasonably sized draw', () {
    final ds = gen.generate(count: 500, seed: 3);
    final labels = ds.examples.map((e) => e.sufficient).toSet();
    expect(labels, containsAll(<bool>{true, false}));
  });

  test('true generative probability is a valid probability', () {
    final ds = gen.generate(count: 300, seed: 9);
    for (final ex in ds.examples) {
      expect(ex.trueProbability, inInclusiveRange(0.0, 1.0));
    }
  });

  test('the planted signal is actually present: a positively-weighted feature '
      'is higher among sufficient examples, a negatively-weighted one lower',
      () {
    final ds = gen.generate(count: 4000, seed: 11);
    final pos = ds.examples.where((e) => e.sufficient).toList();
    final neg = ds.examples.where((e) => !e.sufficient).toList();

    // supportsEdgeCount has a positive ground-truth weight.
    final supPos = _mean(pos.map((e) => e.features['graph.supportsEdgeCount']!));
    final supNeg = _mean(neg.map((e) => e.features['graph.supportsEdgeCount']!));
    expect(supPos, greaterThan(supNeg));

    // contradictsEdgeCount has a negative ground-truth weight.
    final conPos =
        _mean(pos.map((e) => e.features['graph.contradictsEdgeCount']!));
    final conNeg =
        _mean(neg.map((e) => e.features['graph.contradictsEdgeCount']!));
    expect(conPos, lessThan(conNeg));
  });

  test('a zero-weight noise feature does NOT separate the classes much', () {
    final ds = gen.generate(count: 4000, seed: 13);
    final pos = ds.examples.where((e) => e.sufficient).toList();
    final neg = ds.examples.where((e) => !e.sufficient).toList();
    final noisePos = _mean(pos.map((e) => e.features['typing.backspaceRate']!));
    final noiseNeg = _mean(neg.map((e) => e.features['typing.backspaceRate']!));
    // Noise feature is uniform and weightless -> class means should be close.
    expect((noisePos - noiseNeg).abs(), lessThan(0.03));
  });

  test('standardize() reproduces the exact transform a trainer must use', () {
    final ds = gen.generate(count: 1, seed: 5);
    // Midpoint of a range standardizes to 0; the transform is documented and
    // reproducible so a future trainer can recover groundTruthWeights.
    final s = ds.standardize('identity.verifiedShareOfMeasured', 0.5);
    expect(s, closeTo(0.0, 1e-9)); // range [0,1], midpoint 0.5
  });
}
