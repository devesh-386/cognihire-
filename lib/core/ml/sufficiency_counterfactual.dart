import 'dart:math' as math;

import 'sufficiency_model.dart';

/// One answer to "what single input would have to be different?" — Phase 3.4b.
///
/// A counterfactual is only as honest as its feasibility claim. [requiredValue]
/// is exact algebra, but a value the model has never observed is an
/// extrapolation, and presenting one as advice would be a fabrication dressed
/// as arithmetic. So the out-of-range case is carried explicitly in
/// [isFeasible] rather than filtered away or clamped into looking reasonable.
class SufficiencyCounterfactual {
  const SufficiencyCounterfactual({
    required this.feature,
    required this.currentValue,
    required this.requiredValue,
    required this.currentProbability,
    required this.targetProbability,
    required this.effort,
    required this.isFeasible,
  });

  final String feature;

  /// The subject's actual value for [feature].
  final double currentValue;

  /// The value [feature] would have to take — with every other feature held
  /// fixed — for the model to land exactly on the decision boundary. This is
  /// the boundary itself, not a value past it: crossing needs any nudge beyond.
  final double requiredValue;

  final double currentProbability;

  /// The probability [requiredValue] is solved for, i.e. the threshold.
  final double targetProbability;

  /// |delta| as a fraction of the feature's observed range — the only way to
  /// compare "move this by 2 edges" against "move this by 0.3 of a ratio" on
  /// one scale. Above 1.0 means the move is larger than everything the model
  /// has ever seen of this feature, which is why [isFeasible] is false there.
  final double effort;

  /// True when [requiredValue] lies inside the range the model was fit over.
  final bool isFeasible;

  double get delta => requiredValue - currentValue;

  /// True when the feature would have to go up, false when it would go down.
  bool get requiresIncrease => delta > 0;
}

/// Solves single-feature counterfactuals against a linear model — Phase 3.4b.
///
/// ## Why this is algebra, not search
///
/// The logit is `bias + Σ wⱼ·sⱼ`. Holding every feature but *j* fixed, the
/// value of `sⱼ` that puts the logit on a target is a one-line rearrangement:
///
///   `sⱼ' = sⱼ + (targetLogit − currentLogit) / wⱼ`
///
/// No sampling, no optimiser, no approximation — the same reason
/// `SufficiencyAttribution` is exact. When the model stops being linear this
/// class must be replaced by a real search (and must say so), not stretched.
class CounterfactualSearch {
  const CounterfactualSearch._();

  /// Every single-feature move that would put [model] on the decision boundary
  /// at [threshold], ordered feasible-first then by smallest [effort].
  ///
  /// A feature is skipped entirely when it is absent from [rawFeatures] (there
  /// is no current value to move *from*, and inventing one would be a guess),
  /// when its weight is exactly zero (no move changes anything), or when its
  /// observed range is degenerate.
  static List<SufficiencyCounterfactual> singleFeature(
    SufficiencyModel model,
    Map<String, double> rawFeatures, {
    double threshold = 0.5,
  }) {
    if (threshold <= 0.0 || threshold >= 1.0) {
      throw ArgumentError('threshold must be strictly between 0 and 1 '
          '(got $threshold)');
    }

    final attribution = model.explain(rawFeatures);
    final currentLogit = attribution.logit;
    final targetLogit = math.log(threshold / (1 - threshold));

    final out = <SufficiencyCounterfactual>[];
    for (final name in model.featureNames) {
      final current = rawFeatures[name];
      if (current == null) continue;

      final weight = model.weightFor(name)!;
      if (weight == 0.0) continue;

      final range = model.rangeFor(name)!;
      final half = (range.hi - range.lo) / 2;
      if (half == 0) continue;

      final currentStd = model.standardizeFeature(name, current)!;
      final requiredStd = currentStd + (targetLogit - currentLogit) / weight;
      final requiredValue = (range.lo + range.hi) / 2 + requiredStd * half;

      out.add(SufficiencyCounterfactual(
        feature: name,
        currentValue: current,
        requiredValue: requiredValue,
        currentProbability: attribution.probability,
        targetProbability: threshold,
        effort: (requiredValue - current).abs() / (range.hi - range.lo),
        isFeasible: requiredValue >= range.lo - 1e-9 &&
            requiredValue <= range.hi + 1e-9,
      ));
    }

    out.sort((a, b) {
      if (a.isFeasible != b.isFeasible) return a.isFeasible ? -1 : 1;
      return a.effort.compareTo(b.effort);
    });
    return out;
  }
}
