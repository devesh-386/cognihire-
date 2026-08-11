import 'dart:typed_data';

import '../../core/config.dart';
import '../../core/verification/capture_quality_head.dart';
import '../../core/verification/face_engine.dart';

/// Outcome of an enrolment capture attempt.
sealed class EnrolmentOutcome {
  const EnrolmentOutcome();
}

/// A usable reference embedding was captured.
final class EnrolmentCaptured extends EnrolmentOutcome {
  const EnrolmentCaptured({required this.embedding, required this.faceSize});
  final List<double> embedding;
  final int faceSize;
}

/// The capture ran but is not good enough to enrol from. Carries actionable
/// guidance rather than silently enrolling a poor reference — a weak enrolment
/// embedding is the hidden cause of mismatches later in the session.
final class EnrolmentRejected extends EnrolmentOutcome {
  const EnrolmentRejected({required this.reason, this.guidance = const []});
  final String reason;
  final List<String> guidance;
}

/// The capture could not be performed at all.
final class EnrolmentFailed extends EnrolmentOutcome {
  const EnrolmentFailed(this.reason);
  final String reason;
}

/// Captures the reference face embedding used for the rest of the session.
///
/// ## The `minFaceSize` → [CaptureQualityHead] change (R11 in
/// `ML_REDESIGN.md`)
///
/// The gate used to be a hard `faceSize < minFaceSize` cutoff — an arbitrary
/// constant standing in for the real question, "will this capture yield a
/// dependable embedding?" [qualityHead] now answers that instead, as a soft,
/// explainable score rather than a cliff. [minFaceSize] survives as the
/// reference point that score is centred on (and as the default
/// [CaptureQualityHead.provisional]'s calibration), so existing callers and
/// configuration are unaffected — what changed is the shape of the decision,
/// not, yet, the training data behind it. See [CaptureQualityHead]'s doc for
/// why a real 6-feature fit isn't possible until the face service reports
/// blur/pose/confidence.
class EnrolmentController {
  EnrolmentController({
    required this.engine,
    int minFaceSize = AppConfig.minEnrolmentFaceSize,
    CaptureQualityHead? qualityHead,
  })  : minFaceSize = minFaceSize,
        qualityHead = qualityHead ??
            CaptureQualityHead.provisional(referenceFaceSize: minFaceSize);

  final FaceEngine engine;
  final int minFaceSize;
  final CaptureQualityHead qualityHead;

  Future<EnrolmentOutcome> captureFrom(Uint8List? jpegBytes) async {
    if (jpegBytes == null || jpegBytes.isEmpty) {
      return const EnrolmentFailed('No camera frame available');
    }

    final FaceFrameAnalysis analysis;
    try {
      analysis = await engine.analyseFrame(jpegBytes);
    } on FaceEngineUnavailable catch (e) {
      return EnrolmentFailed('Face service unavailable (${e.reason})');
    } catch (e) {
      return EnrolmentFailed('Analysis failed: $e');
    }

    if (!analysis.faceDetected) {
      return const EnrolmentRejected(
        reason: 'No face detected',
        guidance: ['Face the camera directly', 'Check the lighting'],
      );
    }

    if (!analysis.hasEmbedding) {
      return const EnrolmentFailed(
        'Face detected but the recognition engine produced no embedding',
      );
    }

    if (!qualityHead.passes(analysis.faceSize)) {
      return EnrolmentRejected(
        reason: 'Face too small for a dependable reference',
        guidance: [
          'Move closer to the camera',
          ...analysis.recommendations,
        ],
      );
    }

    return EnrolmentCaptured(
      embedding: analysis.embedding!,
      faceSize: analysis.faceSize,
    );
  }
}
