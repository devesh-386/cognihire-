/// Fixture: legitimate scoped scoring vocabulary. This mirrors real usage in
/// lib/core/verification/biometric_metrics.dart and lib/core/ml/*.dart — a
/// per-measurement score is fine; a composite/hire decision is not.
///
/// This file also contains prose that talks ABOUT the ban (like the real
/// workspace_stats.dart doc comment does) to prove the linter ignores
/// comments: "there is no overall score, no hiring score, no hire decision".
class SimilarityMeasurement {
  final double score;
  final List<double> genuineScores;
  final List<double> impostorScores;
  final double rawScore;
  final double maxScore;

  const SimilarityMeasurement({
    required this.score,
    required this.genuineScores,
    required this.impostorScores,
    required this.rawScore,
    required this.maxScore,
  });
}
