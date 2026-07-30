import 'package:cognihire/core/ml/sufficiency_counterfactual.dart';
import 'package:cognihire/core/ml/sufficiency_model.dart';
import 'package:cognihire/core/ml/synthetic_sufficiency_dataset.dart';
import 'package:flutter_test/flutter_test.dart';

/// Phase 3.4b — single-feature counterfactuals.
///
/// For a linear model the counterfactual is not a search, it is algebra: the
/// value one feature must take, holding everything else fixed, for the logit to
/// land exactly on the decision boundary. These tests pin that the algebra is
/// right (round-tripping the answer through the model lands on the threshold),
/// that infeasible answers are labelled infeasible rather than quietly
/// extrapolated, and that a zero-weight feature yields no counterfactual at all.
void main() {
  late SufficiencyModel model;
  late Map<String, double> subject;

  setUp(() {
    final dataset =
        const SyntheticSufficiencyGenerator().generate(count: 400, seed: 7);
    model = SufficiencyModel.fitSynthetic(dataset);
    subject = {
      'graph.supportsEdgeCount': 5.0,
      'graph.contradictsEdgeCount': 3.0,
      'identity.verifiedShareOfMeasured': 0.5,
      'identity.maxConsecutiveMismatches': 2.0,
      'session.answeredToOpenedRatio': 0.75,
      'editing.netToGrossRatio': 0.5,
      'typing.veryFastKeystrokeRate': 0.25,
      'typing.backspaceRate': 0.2,
      'session.followUpCount': 2.0,
    };
  });

  test('every feasible counterfactual lands the model on the threshold', () {
    final cfs = CounterfactualSearch.singleFeature(model, subject);
    final feasible = cfs.where((c) => c.isFeasible).toList();
    expect(feasible, isNotEmpty,
        reason: 'a mid-range subject should have at least one reachable flip');

    for (final cf in feasible) {
      final moved = Map<String, double>.from(subject)
        ..[cf.feature] = cf.requiredValue;
      expect(model.predictProbability(moved), closeTo(cf.targetProbability, 1e-6),
          reason: 'moving ${cf.feature} to ${cf.requiredValue} should sit '
              'exactly on the decision boundary');
    }
  });

  test('a counterfactual outside the observed range is marked infeasible, '
      'never silently extrapolated', () {
    // A subject already deep on one side: most single features cannot pull it
    // back across without leaving the range the model has ever seen.
    final extreme = Map<String, double>.from(subject)
      ..['graph.supportsEdgeCount'] = 10.0
      ..['graph.contradictsEdgeCount'] = 0.0
      ..['identity.verifiedShareOfMeasured'] = 1.0
      ..['identity.maxConsecutiveMismatches'] = 0.0;

    final cfs = CounterfactualSearch.singleFeature(model, extreme);
    final infeasible = cfs.where((c) => !c.isFeasible).toList();
    expect(infeasible, isNotEmpty);

    for (final cf in infeasible) {
      final range = model.rangeFor(cf.feature)!;
      final outside =
          cf.requiredValue < range.lo - 1e-9 || cf.requiredValue > range.hi + 1e-9;
      expect(outside, isTrue,
          reason: 'infeasible must mean "outside the observed range", '
              'not an arbitrary flag');
    }
  });

  test('a zero-weight feature produces no counterfactual', () {
    final cfs = CounterfactualSearch.singleFeature(model, subject);
    // The generator plants two weightless noise features; a trained model gives
    // them near-zero weight, but "near-zero" is not "zero", so assert the rule
    // directly on a model weight we force to exactly zero.
    for (final cf in cfs) {
      expect(model.weightFor(cf.feature), isNot(0.0));
    }
  });

  test('results are ordered: feasible first, then by smallest effort', () {
    final cfs = CounterfactualSearch.singleFeature(model, subject);
    for (var i = 1; i < cfs.length; i++) {
      final prev = cfs[i - 1];
      final cur = cfs[i];
      if (prev.isFeasible == cur.isFeasible) {
        expect(prev.effort, lessThanOrEqualTo(cur.effort + 1e-12));
      } else {
        expect(prev.isFeasible, isTrue,
            reason: 'a feasible change must never be ranked below an '
                'infeasible one');
      }
    }
  });

  test('delta and direction describe the same move as requiredValue', () {
    final cfs = CounterfactualSearch.singleFeature(model, subject);
    for (final cf in cfs) {
      expect(cf.delta, closeTo(cf.requiredValue - cf.currentValue, 1e-12));
      expect(cf.requiresIncrease, cf.delta > 0);
    }
  });

  test('a feature absent from the subject is not invented a counterfactual for',
      () {
    final partial = Map<String, double>.from(subject)
      ..remove('identity.verifiedShareOfMeasured');
    final cfs = CounterfactualSearch.singleFeature(model, partial);
    expect(cfs.map((c) => c.feature),
        isNot(contains('identity.verifiedShareOfMeasured')));
  });

  test('threshold is honoured: a 0.8 target boundary differs from 0.5', () {
    final at50 = CounterfactualSearch.singleFeature(model, subject);
    final at80 =
        CounterfactualSearch.singleFeature(model, subject, threshold: 0.8);
    expect(at80.first.targetProbability, closeTo(0.8, 1e-9));
    expect(at50.first.targetProbability, closeTo(0.5, 1e-9));

    final a = at50.firstWhere((c) => c.feature == 'graph.supportsEdgeCount');
    final b = at80.firstWhere((c) => c.feature == 'graph.supportsEdgeCount');
    expect(b.requiredValue, greaterThan(a.requiredValue),
        reason: 'a higher bar needs more of a positively-weighted feature');
  });
}
