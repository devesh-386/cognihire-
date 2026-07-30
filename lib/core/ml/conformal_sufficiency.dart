/// Split (inductive) conformal prediction for the evidence-sufficiency
/// decision — Phase 3.3b/c.
///
/// ## What it adds on top of a calibrated probability
///
/// A calibrated probability (see `IsotonicCalibrator`) says *how likely*
/// sufficient is. Conformal prediction turns that into a decision with a
/// **distribution-free coverage guarantee**: fixing a risk level `alpha`, the
/// prediction set contains the true label at least `1 - alpha` of the time
/// (marginally), no matter what the model is, as long as calibration and test
/// data are exchangeable. The only price is that on genuinely ambiguous cases
/// the set holds *both* labels — and that is exactly the honest behaviour this
/// project wants: rather than force a verdict at a hard 0.5 cutoff, it returns
/// **Abstain / Unknown** and hands the case to a human.
///
/// That is the "AI measures, humans decide" line made mechanical: the system
/// commits only when the statistics license a commitment, and says so
/// explicitly when they do not. A `committedLabel` of null is not a failure —
/// it is the system declining to manufacture certainty it does not have.
///
/// ## The nonconformity score
///
/// For a calibration example with predicted probability-of-sufficient `p` and
/// true label `y`, the score is how "surprising" the truth was:
///   * `y == sufficient`   -> `1 - p`
///   * `y == insufficient` -> `p`
/// The threshold `q` is the `ceil((n+1)(1-alpha))`-th smallest calibration
/// score (the standard finite-sample-valid conformal quantile). A test label is
/// in the set iff its own nonconformity would not exceed `q`.
class ConformalSufficiency {
  const ConformalSufficiency._(this.qhat, this.alpha, this.calibrationSize);

  /// The conformal threshold: a label is admitted when its nonconformity score
  /// is <= this. In [0, 1] (or 1.0 when the sample is too small for the
  /// requested alpha, which admits everything — a valid, if uninformative,
  /// guarantee).
  final double qhat;

  final double alpha;
  final int calibrationSize;

  static ConformalSufficiency fit({
    required List<double> scoresSufficient,
    required List<bool> labels,
    required double alpha,
  }) {
    if (scoresSufficient.isEmpty ||
        scoresSufficient.length != labels.length) {
      throw ArgumentError(
        'scoresSufficient and labels must be the same nonzero length '
        '(got ${scoresSufficient.length} and ${labels.length})',
      );
    }
    if (alpha <= 0.0 || alpha >= 1.0) {
      throw ArgumentError('alpha must be in (0,1) exclusive (got $alpha)');
    }
    for (final p in scoresSufficient) {
      if (p < 0.0 || p > 1.0 || p.isNaN) {
        throw ArgumentError('probability out of [0,1]: $p');
      }
    }

    final n = scoresSufficient.length;
    final scores = <double>[
      for (var i = 0; i < n; i++)
        labels[i] ? 1.0 - scoresSufficient[i] : scoresSufficient[i],
    ]..sort();

    // Rank k = ceil((n+1)(1-alpha)), 1-based. If it exceeds n the sample is too
    // small to certify this alpha; qhat = 1.0 admits every label (still a valid
    // >= 1-alpha guarantee, just maximally cautious).
    final k = ((n + 1) * (1 - alpha)).ceil();
    final qhat = k > n ? 1.0 : scores[k - 1];

    return ConformalSufficiency._(qhat, alpha, n);
  }

  /// The prediction set for a probability-of-sufficient [scoreSufficient].
  ConformalPrediction predict(double scoreSufficient) {
    final p = scoreSufficient;
    // sufficient admitted iff its nonconformity (1 - p) <= qhat.
    final includesSufficient = (1.0 - p) <= qhat + _tol;
    // insufficient admitted iff its nonconformity (p) <= qhat.
    final includesInsufficient = p <= qhat + _tol;
    return ConformalPrediction._(includesSufficient, includesInsufficient);
  }

  // A tiny tolerance so a score exactly on the boundary is admitted rather than
  // dropped to a floating-point hair's breadth — dropping it would silently
  // erode the coverage guarantee.
  static const double _tol = 1e-12;
}

/// The outcome of a conformal decision: which labels the set admits, and the
/// committed label when (and only when) the set is a singleton.
class ConformalPrediction {
  const ConformalPrediction._(this.includesSufficient, this.includesInsufficient);

  final bool includesSufficient;
  final bool includesInsufficient;

  /// True when the set does not pin down a single label — either it holds both
  /// (ambiguous) or neither (both labels were too surprising). Both are
  /// [committedLabel] == null: the system declines to decide.
  bool get isAbstain => includesSufficient == includesInsufficient;

  /// The single admitted label, or null when [isAbstain]. `true` == sufficient.
  bool? get committedLabel {
    if (isAbstain) return null;
    return includesSufficient;
  }

  /// Whether the set covers [trueLabel] — the event the coverage guarantee is
  /// about. An abstain that holds both labels still counts as covered; that is
  /// the honest cost of the guarantee, not a loophole.
  bool covers(bool trueLabel) =>
      trueLabel ? includesSufficient : includesInsufficient;

  int get setSize =>
      (includesSufficient ? 1 : 0) + (includesInsufficient ? 1 : 0);

  @override
  String toString() => 'ConformalPrediction(sufficient=$includesSufficient, '
      'insufficient=$includesInsufficient, '
      '${isAbstain ? "ABSTAIN" : "commit=$committedLabel"})';
}
