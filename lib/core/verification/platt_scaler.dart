import 'dart:math' as math;

/// Calibrates a raw similarity score into a probability via logistic
/// regression over a single feature — the family of calibration Platt
/// scaling popularised for SVM outputs, applied here to identity-match
/// similarity per `ML_REDESIGN.md` §4.2.
///
/// ## What this class is, and pointedly is not
///
/// [fit] performs real gradient-descent logistic regression against whatever
/// (score, label) pairs it is given — it has no baked-in "the right"
/// coefficients, and two calls with different data produce different
/// scalers. It is genuinely useful today for calibrating within-session
/// consistency comparisons even before Phase 2's paired-capture dataset
/// exists. What it is *not*, until fit on real biometric ground truth, is a
/// validated production identity calibration — [isCalibrated] plus the
/// caller's own audit trail is how a consumer tells the difference between
/// "fit on synthetic/demo data" and "fit on Phase 2 data", since this class
/// has no way to know which its inputs were.
class PlattScaler {
  const PlattScaler._({
    required double weight,
    required double bias,
    required this.isCalibrated,
  })  : _w = weight,
        _b = bias;

  final double _w;
  final double _b;

  /// False for [PlattScaler.uncalibrated] and true for anything returned by
  /// [fit]. Does not itself vouch for the quality of the fit — only that a
  /// fit was attempted.
  final bool isCalibrated;

  /// A pass-through scaler for use before any calibration data exists.
  ///
  /// Returns the raw score, clamped to [0, 1], completely unchanged — no
  /// logistic transform. This is the honest alternative to inventing
  /// coefficients: a caller that has no labelled data yet should say so by
  /// using this, not by asking [fit] to manufacture a calibration from
  /// nothing.
  const factory PlattScaler.uncalibrated() = _UncalibratedScaler;

  /// A scaler with explicitly hand-set coefficients — a stand-in for a real
  /// fit when no labelled data exists yet, but one that produces a genuine
  /// sigmoid curve (unlike [uncalibrated]'s flat pass-through) so a caller
  /// gets soft, monotonic behaviour around a chosen reference point instead
  /// of either a hard cutoff or no transform at all.
  ///
  /// [isCalibrated] is false for the result, same as [uncalibrated] — the
  /// coefficients came from a human choice, not from fitting real labelled
  /// data, and that distinction must survive into anything downstream that
  /// checks [isCalibrated] before trusting a score as validated.
  const factory PlattScaler.withCoefficients({
    required double weight,
    required double bias,
  }) = _HandSetScaler;

  /// Fit A logistic-regression scaler on (score, label) pairs via batch
  /// gradient descent with a small L2 penalty for numerical stability. Both
  /// classes must be present — a scaler fit on one class has nothing to
  /// discriminate and would be a false calibration, not a real one.
  factory PlattScaler.fit({
    required List<double> scores,
    required List<bool> labels,
    int iterations = 2000,
    double learningRate = 0.1,
    double l2 = 0.01,
  }) {
    if (scores.isEmpty || scores.length != labels.length) {
      throw ArgumentError(
        'scores and labels must be the same nonzero length '
        '(got ${scores.length} scores, ${labels.length} labels)',
      );
    }
    if (!labels.contains(true) || !labels.contains(false)) {
      throw ArgumentError(
        'fit requires both classes present in labels — a scaler cannot '
        'discriminate genuine from impostor scores from one class alone',
      );
    }

    final n = scores.length;
    var w = 0.0;
    var b = 0.0;

    for (var iter = 0; iter < iterations; iter++) {
      var gradW = 0.0;
      var gradB = 0.0;
      for (var i = 0; i < n; i++) {
        final z = w * scores[i] + b;
        final p = _sigmoid(z);
        final error = p - (labels[i] ? 1.0 : 0.0);
        gradW += error * scores[i];
        gradB += error;
      }
      w -= learningRate * (gradW / n + l2 * w);
      b -= learningRate * (gradB / n);
    }

    return PlattScaler._(weight: w, bias: b, isCalibrated: true);
  }

  /// Calibrated probability for [rawScore]. Always in [0, 1].
  double predict(double rawScore) => _sigmoid(_w * rawScore + _b);

  static double _sigmoid(double z) {
    // Clamp before exp so a large-magnitude z (a well-separated fit run for
    // many iterations) cannot overflow to infinity/NaN.
    final clamped = z.clamp(-30.0, 30.0);
    return 1.0 / (1.0 + math.exp(-clamped));
  }
}

class _UncalibratedScaler implements PlattScaler {
  const _UncalibratedScaler();

  @override
  bool get isCalibrated => false;

  @override
  double predict(double rawScore) => rawScore.clamp(0.0, 1.0);

  @override
  double get _w => throw UnimplementedError();

  @override
  double get _b => throw UnimplementedError();
}

class _HandSetScaler implements PlattScaler {
  const _HandSetScaler({required double weight, required double bias})
      : _w = weight,
        _b = bias;

  @override
  final double _w;

  @override
  final double _b;

  @override
  bool get isCalibrated => false;

  @override
  double predict(double rawScore) => PlattScaler._sigmoid(_w * rawScore + _b);
}
