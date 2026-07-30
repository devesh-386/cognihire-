import 'dart:convert';

import 'isotonic_calibrator.dart';
import 'sufficiency_model.dart';

/// A model artifact produced by the Python trainer in `service/ml/`, as bundled
/// at `assets/ml/sufficiency_model.json`.
///
/// ## Why this wrapper exists instead of just calling the two loaders
///
/// The artifact may or may not contain a calibrator, and the *reason* it might
/// not is the interesting part. The exporter embeds one only when it measurably
/// improves held-out ECE without worsening log loss; on the current synthetic
/// data it does not, so it is deliberately absent. That is a measured decision,
/// not a missing feature.
///
/// If the app simply called `predictProbability` and ignored a calibration
/// section it happened not to find, then the day one *is* earned nothing would
/// pick it up, and the shipped probability would silently differ from the one
/// the training report vouched for. [probabilityFor] is the single scoring path
/// that cannot drift that way: it applies the calibrator when present and does
/// not when it is not, and [isCalibrated] lets any surface that shows a
/// probability say which of the two it is showing.
class TrainedArtifact {
  const TrainedArtifact({required this.model, required this.calibrator});

  final SufficiencyModel model;

  /// Null when the trainer judged calibration not worth shipping. Absence here
  /// is evidence-backed, not an oversight — see the class doc.
  final IsotonicCalibrator? calibrator;

  bool get isCalibrated => calibrator != null;

  /// The probability the app should display, calibrated iff a calibrator was
  /// shipped. Anything user-facing must come through here rather than calling
  /// [SufficiencyModel.predictProbability] directly, or the two paths can
  /// disagree.
  double probabilityFor(Map<String, double> rawFeatures) {
    final raw = model.predictProbability(rawFeatures);
    return calibrator?.calibrate(raw) ?? raw;
  }

  /// The uncalibrated score, kept reachable on purpose. A calibrator is a
  /// correction to a model's confidence, not a replacement for it, and an
  /// explanation is computed in the model's own space — so the attribution
  /// arithmetic must still be able to reach the number it decomposes.
  double uncalibratedProbabilityFor(Map<String, double> rawFeatures) =>
      model.predictProbability(rawFeatures);

  factory TrainedArtifact.fromJson(Map<String, dynamic> json) {
    final model = SufficiencyModel.fromTrainedJson(json);

    final calibration = json['calibration'];
    if (calibration == null) {
      return TrainedArtifact(model: model, calibrator: null);
    }
    if (calibration is! Map) {
      throw const FormatException(
        'calibration section must be an object when present',
      );
    }
    return TrainedArtifact(
      model: model,
      calibrator: IsotonicCalibrator.fromTrainedJson(
        Map<String, dynamic>.from(calibration),
      ),
    );
  }

  factory TrainedArtifact.fromJsonString(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map) {
      throw const FormatException('model artifact must be a JSON object');
    }
    return TrainedArtifact.fromJson(Map<String, dynamic>.from(decoded));
  }

  /// The bundled asset path. Loading is left to the caller so this file stays
  /// free of a Flutter binding dependency and remains testable from plain Dart.
  static const String assetPath = 'assets/ml/sufficiency_model.json';
}
