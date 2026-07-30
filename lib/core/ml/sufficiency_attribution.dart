/// Why the model produced the probability it did — Phase 3.4a.
///
/// For a logistic model the decomposition is **exact**, not an approximation:
/// the logit is a plain sum of per-feature contributions plus a bias, so each
/// feature's push toward or away from "sufficient" is simply
/// `weight * standardizedValue`. This is the honest form of "explainability" —
/// there is no post-hoc surrogate, no sampling, no story fitted after the fact;
/// the explanation *is* the arithmetic the decision was made from. (TreeSHAP
/// would be the counterpart once a tree model replaces this linear reference.)
class SufficiencyAttribution {
  const SufficiencyAttribution({
    required this.bias,
    required this.logit,
    required this.probability,
    required this.contributions,
  });

  final double bias;

  /// bias + sum of all [contributions]. Feeding this through the logistic
  /// function gives [probability].
  final double logit;

  final double probability;

  /// Every feature's signed contribution to [logit], sorted by absolute impact
  /// (largest first).
  final List<FeatureContribution> contributions;

  /// The [n] most impactful contributions (by magnitude), largest first.
  List<FeatureContribution> topContributors(int n) =>
      contributions.take(n).toList();
}

/// One feature's exact push on the decision.
class FeatureContribution {
  const FeatureContribution({
    required this.feature,
    required this.rawValue,
    required this.standardizedValue,
    required this.weight,
    required this.contribution,
  });

  final String feature;
  final double rawValue;
  final double standardizedValue;
  final double weight;

  /// `weight * standardizedValue` — the signed amount this feature added to the
  /// logit. Positive pushes toward sufficient, negative away from it.
  final double contribution;

  /// True when this feature pushed the decision toward "sufficient".
  bool get pushesTowardSufficient => contribution > 0;
}
