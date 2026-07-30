import 'platt_scaler.dart';

/// Predicts $q_{capture} \in [0,1]$ — "will this capture yield a dependable
/// embedding?" — replacing the arbitrary `AppConfig.minEnrolmentFaceSize`
/// hard cutoff per `ML_REDESIGN.md` R11/§4.11.
///
/// ## What this class is honestly built from right now
///
/// The full spec is a 6-feature logistic regression (face area, blur, yaw,
/// pitch, exposure, detector confidence) fit on [selfSupervisedStabilityLabels
/// (in `capture_stability_labels.dart`)]. Today the face-analysis service
/// (`face_engine.dart`) only reports face area and an unqualified brightness
/// figure with no "not measured" representation to distinguish a genuinely
/// dark frame from a value the service simply didn't set — using it here
/// would risk exactly the kind of false-zero-as-signal error this project's
/// own rules exist to prevent. So this head uses **face area alone** until
/// the service is extended to report blur/pose/confidence and brightness
/// gains real null semantics. That gap is deliberate and tracked, not hidden.
///
/// ## [CaptureQualityHead.provisional] vs [CaptureQualityHead.fitted]
///
/// [provisional] replaces the *shape* of the old decision — a hard cutoff —
/// with a soft sigmoid centred on the same reference face size, without
/// claiming to have learned anything: [isCalibrated] is false, matching
/// [PlattScaler.withCoefficients]. [fitted] wraps a scaler actually produced
/// by [PlattScaler.fit] against real stability-labelled data, once Phase 2
/// or a self-supervised in-session pass has produced any.
class CaptureQualityHead {
  const CaptureQualityHead._(this._scaler, this.referenceFaceSize);

  final PlattScaler _scaler;

  /// The face size (px²) this head's decision is centred on. Kept for
  /// diagnostics/logging — the score is what callers should act on.
  final int referenceFaceSize;

  /// A soft cutoff around [referenceFaceSize], shaped like the old hard
  /// threshold but continuous: scores 0.5 exactly at the reference, rising
  /// sharply above it and falling sharply below, per [steepness].
  factory CaptureQualityHead.provisional({
    required int referenceFaceSize,
    double steepness = 8.0,
  }) {
    if (referenceFaceSize <= 0) {
      throw ArgumentError.value(
        referenceFaceSize,
        'referenceFaceSize',
        'must be positive',
      );
    }
    // Operates on the normalised ratio (see [score]): z = steepness*(ratio-1)
    // so the curve centres exactly on ratio == 1, i.e. faceArea ==
    // referenceFaceSize, regardless of the reference's absolute magnitude.
    return CaptureQualityHead._(
      PlattScaler.withCoefficients(weight: steepness, bias: -steepness),
      referenceFaceSize,
    );
  }

  /// Wrap a scaler already fit ([PlattScaler.fit]) on real stability-labelled
  /// `(faceArea / referenceFaceSize, isStable)` pairs — normalised the same
  /// way [score] normalises at prediction time, so a fit and its later use
  /// agree on scale.
  factory CaptureQualityHead.fitted({
    required PlattScaler scaler,
    required int referenceFaceSize,
  }) =>
      CaptureQualityHead._(scaler, referenceFaceSize);

  /// False for [provisional] heads; true only when built from a real
  /// [PlattScaler.fit].
  bool get isCalibrated => _scaler.isCalibrated;

  /// $q_{capture}$ for a capture with this face area, in [0, 1].
  ///
  /// Normalises by [referenceFaceSize] before scoring — a ratio, not a raw
  /// pixel count — so the same head shape works regardless of the reference's
  /// absolute magnitude, and so [provisional] and [fitted] heads are scored
  /// identically rather than one needing pre-scaled input and the other not.
  double score(int faceAreaPx) =>
      _scaler.predict(faceAreaPx / referenceFaceSize);

  bool passes(int faceAreaPx, {double qualityThreshold = 0.5}) =>
      score(faceAreaPx) >= qualityThreshold;
}
