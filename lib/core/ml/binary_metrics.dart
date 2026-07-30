import 'dart:math' as math;

/// Held-out evaluation metrics for a binary probabilistic classifier — the
/// Phase 3.2d/3.3 measurement layer.
///
/// ## Why these four, and why calibration is first-class
///
/// A model that ranks well (high [auc]) can still be badly *calibrated* — it
/// may say "0.95" when it is right only 60% of the time. For a system whose
/// entire pitch is "the AI measures, humans decide", a probability a reviewer
/// cannot take at face value is worse than useless: it launders overconfidence
/// as evidence. So this reports discrimination ([auc]) and calibration
/// ([expectedCalibrationError], with the underlying [reliabilityBins]) side by
/// side, plus proper scoring rules ([brier], [logLoss]) that penalise both at
/// once.
///
/// Every metric is computed honestly: [auc] is null when only one class is
/// present (it is undefined, not 0.5), and [logLoss] clamps probabilities away
/// from 0 and 1 so a single confident-and-wrong prediction cannot report an
/// infinite loss that hides everything else.
class BinaryMetrics {
  const BinaryMetrics({
    required this.count,
    required this.positiveCount,
    required this.auc,
    required this.brier,
    required this.logLoss,
    required this.accuracy,
    required this.expectedCalibrationError,
    required this.reliabilityBins,
  });

  final int count;
  final int positiveCount;

  /// Area under the ROC curve (Mann–Whitney form, tie-aware). Null when only
  /// one class is present — with no negatives (or no positives) there is no
  /// pair to rank and AUC is genuinely undefined.
  final double? auc;

  /// Mean squared error between probability and outcome. Lower is better.
  final double brier;

  /// Mean negative log-likelihood, with probabilities clamped to [_eps,
  /// 1-_eps]. Lower is better.
  final double logLoss;

  /// Fraction correct when thresholding at 0.5.
  final double accuracy;

  /// Expected calibration error: the average gap between confidence and
  /// observed accuracy across [reliabilityBins], weighted by bin population.
  /// Null only if [count] is zero (guarded against at construction).
  final double expectedCalibrationError;

  final List<ReliabilityBin> reliabilityBins;

  static const double _eps = 1e-12;

  static BinaryMetrics evaluate(
    List<double> probabilities,
    List<bool> labels, {
    int calibrationBins = 10,
  }) {
    if (probabilities.isEmpty || probabilities.length != labels.length) {
      throw ArgumentError(
        'probabilities and labels must be the same nonzero length '
        '(got ${probabilities.length} and ${labels.length})',
      );
    }
    if (calibrationBins < 1) {
      throw ArgumentError('calibrationBins must be >= 1');
    }
    for (final p in probabilities) {
      if (p < 0.0 || p > 1.0 || p.isNaN) {
        throw ArgumentError('probability out of [0,1]: $p');
      }
    }

    final n = probabilities.length;
    final positives = labels.where((l) => l).length;
    final negatives = n - positives;

    // --- Brier, log loss, accuracy ---
    var brierSum = 0.0;
    var logLossSum = 0.0;
    var correct = 0;
    for (var i = 0; i < n; i++) {
      final y = labels[i] ? 1.0 : 0.0;
      final p = probabilities[i];
      brierSum += (p - y) * (p - y);
      final pc = p.clamp(_eps, 1 - _eps);
      logLossSum += -(y * math.log(pc) + (1 - y) * math.log(1 - pc));
      if ((p >= 0.5) == labels[i]) correct++;
    }

    // --- AUC via average-rank Mann–Whitney ---
    double? auc;
    if (positives > 0 && negatives > 0) {
      final ranks = _averageRanks(probabilities);
      var rankSumPos = 0.0;
      for (var i = 0; i < n; i++) {
        if (labels[i]) rankSumPos += ranks[i];
      }
      auc = (rankSumPos - positives * (positives + 1) / 2) /
          (positives * negatives);
    }

    // --- Reliability bins + ECE ---
    final bins = _reliability(probabilities, labels, calibrationBins);
    var ece = 0.0;
    for (final b in bins) {
      if (b.count == 0) continue;
      ece += (b.count / n) * (b.meanConfidence - b.observedAccuracy).abs();
    }

    return BinaryMetrics(
      count: n,
      positiveCount: positives,
      auc: auc,
      brier: brierSum / n,
      logLoss: logLossSum / n,
      accuracy: correct / n,
      expectedCalibrationError: ece,
      reliabilityBins: bins,
    );
  }

  /// Fractional (average) ranks, 1-based, so tied scores share the mean of the
  /// ranks they span — the tie handling that makes a boundary tie score
  /// exactly 0.5 in AUC rather than 0 or 1.
  static List<double> _averageRanks(List<double> values) {
    final n = values.length;
    final order = List<int>.generate(n, (i) => i)
      ..sort((a, b) => values[a].compareTo(values[b]));
    final ranks = List<double>.filled(n, 0.0);
    var i = 0;
    while (i < n) {
      var j = i;
      while (j + 1 < n && values[order[j + 1]] == values[order[i]]) {
        j++;
      }
      // Positions i..j (0-based) share ranks (i+1)..(j+1); average is
      // (i + j)/2 + 1.
      final avg = (i + j) / 2 + 1;
      for (var k = i; k <= j; k++) {
        ranks[order[k]] = avg;
      }
      i = j + 1;
    }
    return ranks;
  }

  static List<ReliabilityBin> _reliability(
    List<double> probs,
    List<bool> labels,
    int binCount,
  ) {
    final sums = List<double>.filled(binCount, 0.0);
    final posCounts = List<int>.filled(binCount, 0);
    final counts = List<int>.filled(binCount, 0);
    for (var i = 0; i < probs.length; i++) {
      // p == 1.0 lands in the last bin, not an out-of-range (binCount) index.
      var idx = (probs[i] * binCount).floor();
      if (idx >= binCount) idx = binCount - 1;
      sums[idx] += probs[i];
      if (labels[i]) posCounts[idx]++;
      counts[idx]++;
    }
    return [
      for (var b = 0; b < binCount; b++)
        ReliabilityBin(
          lowerEdge: b / binCount,
          upperEdge: (b + 1) / binCount,
          count: counts[b],
          meanConfidence: counts[b] == 0 ? 0.0 : sums[b] / counts[b],
          observedAccuracy:
              counts[b] == 0 ? 0.0 : posCounts[b] / counts[b],
        ),
    ];
  }
}

/// One bucket of a reliability diagram: the model's mean confidence in this
/// probability band versus how often it was actually right there.
class ReliabilityBin {
  const ReliabilityBin({
    required this.lowerEdge,
    required this.upperEdge,
    required this.count,
    required this.meanConfidence,
    required this.observedAccuracy,
  });

  final double lowerEdge;
  final double upperEdge;
  final int count;
  final double meanConfidence;
  final double observedAccuracy;
}
