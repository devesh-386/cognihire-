/// FAR, FRR, and EER over labelled similarity scores.
///
/// ## Scope, stated plainly
///
/// These are pure statistics over whatever `(score, label)` data is supplied.
/// They do not know where the scores came from, do not assume any particular
/// distribution, and hold no reference dataset of their own — a caller must
/// bring genuine and impostor score samples. Until Phase 2 (`ML_REDESIGN.md`
/// §5) produces paired captures from real candidates, any numbers these
/// functions produce describe *whatever was passed in*, synthetic or real,
/// and must be labelled as such wherever they are reported. Citing an EER
/// computed here as if it validated the deployed threshold, without first
/// running it against Phase 2 data, would be the same category of error the
/// project's citation-discipline rule (`ML_REDESIGN.md` §0) exists to catch.
library;

/// The threshold at which [BiometricMetrics.equalErrorRate] found FAR and FRR
/// closest to equal, and the (averaged) error rate there.
class EqualErrorResult {
  const EqualErrorResult({required this.threshold, required this.eer});

  final double threshold;
  final double eer;
}

abstract final class BiometricMetrics {
  /// Fraction of impostor scores that would be wrongly accepted at
  /// [threshold] — scored at or above it despite being a different person.
  static double falseAcceptRate({
    required List<double> impostorScores,
    required double threshold,
  }) {
    if (impostorScores.isEmpty) {
      throw ArgumentError('impostorScores must not be empty');
    }
    final accepted = impostorScores.where((s) => s >= threshold).length;
    return accepted / impostorScores.length;
  }

  /// Fraction of genuine scores that would be wrongly rejected at
  /// [threshold] — scored below it despite being the enrolled person.
  static double falseRejectRate({
    required List<double> genuineScores,
    required double threshold,
  }) {
    if (genuineScores.isEmpty) {
      throw ArgumentError('genuineScores must not be empty');
    }
    final rejected = genuineScores.where((s) => s < threshold).length;
    return rejected / genuineScores.length;
  }

  /// Sweeps candidate thresholds (every genuine and impostor score value,
  /// which is sufficient — FAR/FRR only change at those points) and returns
  /// the threshold where |FAR - FRR| is smallest, along with the error rate
  /// there.
  static EqualErrorResult equalErrorRate({
    required List<double> genuineScores,
    required List<double> impostorScores,
  }) {
    if (genuineScores.isEmpty || impostorScores.isEmpty) {
      throw ArgumentError(
        'both genuineScores and impostorScores must be non-empty',
      );
    }

    final candidates = <double>{...genuineScores, ...impostorScores}.toList()
      ..sort();

    var bestThreshold = candidates.first;
    var bestGap = double.infinity;
    var bestEer = 1.0;

    for (final t in candidates) {
      final far = falseAcceptRate(impostorScores: impostorScores, threshold: t);
      final frr = falseRejectRate(genuineScores: genuineScores, threshold: t);
      final gap = (far - frr).abs();
      if (gap < bestGap) {
        bestGap = gap;
        bestThreshold = t;
        bestEer = (far + frr) / 2;
      }
    }

    return EqualErrorResult(threshold: bestThreshold, eer: bestEer);
  }
}
