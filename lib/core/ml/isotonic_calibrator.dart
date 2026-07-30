/// Isotonic (monotonic, non-parametric) recalibration of classifier scores —
/// Phase 3.3a.
///
/// ## What it does and why it belongs here
///
/// A model can rank well yet be miscalibrated: it says 0.95 where it is right
/// 70% of the time. [BinaryMetrics.expectedCalibrationError] measures that gap;
/// this class closes it. It fits a monotonic non-decreasing step function from
/// raw score to empirical probability using the Pool Adjacent Violators
/// Algorithm (PAVA) on a held-out **calibration fold** — never the training or
/// test fold, or the correction would be fit and judged on the same data.
///
/// Isotonic (vs. Platt/sigmoid) because it assumes only monotonicity, not a
/// logistic shape — the right default when we do not want to impose a
/// functional form on a model whose miscalibration could be any monotone
/// distortion. The cost is that it needs enough calibration data not to
/// overfit; on a small fold, Platt scaling ([PlattScaler]) is the more stable
/// choice, and the two are meant to coexist.
///
/// This maps scores to probabilities and asserts nothing about whether the
/// underlying model is valid — a well-calibrated wrong model is still wrong.
/// Calibration is necessary for an honest probability, not sufficient for a
/// trustworthy verdict.
class IsotonicCalibrator {
  const IsotonicCalibrator._(this._blockMaxScore, this._blockValue);

  /// The (ascending) upper score bound of each pooled block, aligned with
  /// [_blockValue]. A query score is mapped to the first block whose bound is
  /// >= the score.
  final List<double> _blockMaxScore;
  final List<double> _blockValue;

  /// Fit on held-out (score, label) pairs via PAVA. Both fields must be the
  /// same nonzero length.
  factory IsotonicCalibrator.fit(List<double> scores, List<bool> labels) {
    if (scores.isEmpty || scores.length != labels.length) {
      throw ArgumentError(
        'scores and labels must be the same nonzero length '
        '(got ${scores.length} and ${labels.length})',
      );
    }

    // Sort by score; ties keep their relative order (stable enough — pooling
    // is order-independent within equal scores).
    final order = List<int>.generate(scores.length, (i) => i)
      ..sort((a, b) => scores[a].compareTo(scores[b]));

    // Each block: pooled sum of targets, total weight (count), and the max
    // score it spans. Start with one singleton block per point, then pool any
    // adjacent pair that violates non-decreasing means.
    final sums = <double>[];
    final weights = <double>[];
    final maxScore = <double>[];
    for (final i in order) {
      var s = labels[i] ? 1.0 : 0.0;
      var w = 1.0;
      var ms = scores[i];
      // Pool back into previous blocks while they violate monotonicity.
      while (sums.isNotEmpty &&
          sums.last / weights.last > s / w) {
        s += sums.removeLast();
        w += weights.removeLast();
        final poppedMax = maxScore.removeLast();
        if (poppedMax > ms) ms = poppedMax;
      }
      sums.add(s);
      weights.add(w);
      maxScore.add(ms);
    }

    final values = [
      for (var b = 0; b < sums.length; b++) sums[b] / weights[b],
    ];
    return IsotonicCalibrator._(maxScore, values);
  }

  /// Reconstruct a calibrator fitted by the Python trainer (`service/ml/`) from
  /// the `calibration` section of a model artifact.
  ///
  /// The blocks are taken as-is and evaluated by [calibrate] — the same step
  /// function [fit] produces. That equivalence is the whole reason the Python
  /// side hand-rolls PAVA instead of exporting scikit-learn's knots: scikit-learn
  /// interpolates linearly between knots, this steps between block bounds, and
  /// a calibrator that disagrees with the one that was measured is worse than
  /// no calibrator at all.
  factory IsotonicCalibrator.fromTrainedJson(Map<String, dynamic> json) {
    final method = json['method'];
    if (method != 'isotonic') {
      throw FormatException('unsupported calibration method "$method"');
    }
    // Guards against a future exporter switching to an interpolated form and
    // this loader silently evaluating it as a step function.
    final representation = json['representation'];
    if (representation != 'pavaBlocks') {
      throw FormatException(
        'unsupported calibration representation "$representation" '
        '(this build evaluates pavaBlocks as a step function)',
      );
    }

    final bounds = _numList(json['blockMaxScore'], 'blockMaxScore');
    final values = _numList(json['blockValue'], 'blockValue');

    if (bounds.isEmpty) {
      throw const FormatException('calibration section has no blocks');
    }
    if (bounds.length != values.length) {
      throw FormatException(
        'calibration blocks are misaligned '
        '(${bounds.length} bounds vs ${values.length} values)',
      );
    }
    for (var i = 1; i < bounds.length; i++) {
      // Both sequences must be non-decreasing or this is not an isotonic fit,
      // and calibrate()'s first-match scan would return the wrong block.
      if (bounds[i] < bounds[i - 1]) {
        throw const FormatException('calibration block bounds are not ascending');
      }
      if (values[i] < values[i - 1]) {
        throw const FormatException('calibration values are not monotonic');
      }
    }
    for (final v in values) {
      if (v < 0.0 || v > 1.0) {
        throw FormatException('calibrated value $v is outside [0, 1]');
      }
    }

    return IsotonicCalibrator._(bounds, values);
  }

  static List<double> _numList(Object? value, String field) {
    if (value is! List) {
      throw FormatException('$field must be a list');
    }
    return [
      for (final v in value)
        if (v is num && v.toDouble().isFinite)
          v.toDouble()
        else
          throw FormatException('$field contains a non-finite entry ($v)'),
    ];
  }

  /// The calibrated probability for a raw [score]. Scores below the first
  /// block's range clamp to the first block's value; scores above the last
  /// clamp to the last — extrapolation beyond the calibration data's support
  /// is held flat rather than invented.
  double calibrate(double score) {
    for (var b = 0; b < _blockMaxScore.length; b++) {
      if (score <= _blockMaxScore[b]) return _blockValue[b];
    }
    return _blockValue.last;
  }
}
