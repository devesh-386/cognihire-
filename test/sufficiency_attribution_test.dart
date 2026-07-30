import 'package:cognihire/core/ml/sufficiency_model.dart';
import 'package:cognihire/core/ml/synthetic_sufficiency_dataset.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const gen = SyntheticSufficiencyGenerator();

  test('the attributed logit equals the model bias plus every contribution '
      '(exact for a linear model, not an approximation)', () {
    final ds = gen.generate(count: 2000, seed: 1);
    final model = SufficiencyModel.fitSynthetic(ds);
    final ex = ds.examples.first;

    final att = model.explain(ex.features);
    final summed = att.contributions.fold<double>(
        att.bias, (acc, c) => acc + c.contribution);
    expect(att.logit, closeTo(summed, 1e-9));
    // And the reported probability matches predictProbability exactly.
    expect(att.probability,
        closeTo(model.predictProbability(ex.features), 1e-12));
  });

  test('contributions are sorted by absolute impact, largest first', () {
    final ds = gen.generate(count: 2000, seed: 2);
    final model = SufficiencyModel.fitSynthetic(ds);
    final att = model.explain(ds.examples.first.features);
    for (var i = 1; i < att.contributions.length; i++) {
      expect(att.contributions[i - 1].contribution.abs(),
          greaterThanOrEqualTo(att.contributions[i].contribution.abs()));
    }
  });

  test('each contribution is exactly weight x standardized value', () {
    final ds = gen.generate(count: 2000, seed: 3);
    final model = SufficiencyModel.fitSynthetic(ds);
    final att = model.explain(ds.examples.first.features);
    for (final c in att.contributions) {
      expect(c.contribution, closeTo(c.weight * c.standardizedValue, 1e-12));
    }
  });

  test('a strongly-supported example attributes positive impact to support '
      'evidence', () {
    final ds = gen.generate(count: 2000, seed: 4);
    final model = SufficiencyModel.fitSynthetic(ds);
    // Hand-build a feature map with lots of support, no contradiction.
    final features = Map<String, double>.from(ds.examples.first.features)
      ..['graph.supportsEdgeCount'] = 10.0
      ..['graph.contradictsEdgeCount'] = 0.0;
    final att = model.explain(features);
    final support = att.contributions
        .firstWhere((c) => c.feature == 'graph.supportsEdgeCount');
    expect(support.contribution, greaterThan(0));
  });

  test('topContributors returns at most n, most impactful first', () {
    final ds = gen.generate(count: 2000, seed: 5);
    final model = SufficiencyModel.fitSynthetic(ds);
    final att = model.explain(ds.examples.first.features);
    final top = att.topContributors(3);
    expect(top.length, lessThanOrEqualTo(3));
    expect(top.first.contribution.abs(),
        greaterThanOrEqualTo(top.last.contribution.abs()));
  });
}
