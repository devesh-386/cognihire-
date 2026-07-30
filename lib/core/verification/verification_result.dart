/// The outcome of a single identity verification attempt.
///
/// DESIGN RULE — the reason this is a sealed class and not a bool + double:
///
/// The reference implementation this project learns from returned
/// `{"verified": true, "similarity_score": 98.7}` whenever no enrolled face
/// profile existed — a confident *pass* fabricated from missing data. The same
/// codebase also invented resume-parsing output on an empty match, and shipped
/// a brightness heuristic that logged "phone detected (Camera Verified)" when a
/// desk lamp was on.
///
/// Those are not unrelated bugs. They are one habit: treating "I could not
/// measure this" as "this passed". A system whose entire pitch is verifiable
/// evidence cannot afford that habit anywhere.
///
/// So "could not measure" is modelled here as its own variant, [Unchecked].
/// It has no similarity score, because there is no honest number to report.
/// Callers must handle it explicitly; there is no default that silently
/// becomes a pass.
sealed class VerificationResult {
  const VerificationResult({required this.at});

  /// When this attempt occurred.
  final DateTime at;

  /// True only when a real comparison ran and cleared the threshold.
  /// [Unchecked] deliberately answers false — absence of evidence is not a pass.
  bool get isVerified => switch (this) {
        Verified() => true,
        Mismatch() => false,
        Unchecked() => false,
      };

  /// True when the system actually managed to measure something.
  /// Use this to distinguish "failed" from "never ran".
  bool get didMeasure => switch (this) {
        Verified() => true,
        Mismatch() => true,
        Unchecked() => false,
      };
}

/// A real comparison ran and cleared the threshold.
final class Verified extends VerificationResult {
  const Verified({required this.similarity, required super.at});

  /// Cosine similarity rescaled to 0–100. See [IdentityMatcher] for why this
  /// scale does not start at zero.
  final double similarity;
}

/// A real comparison ran and fell below the threshold.
final class Mismatch extends VerificationResult {
  const Mismatch({
    required this.similarity,
    required this.strike,
    required this.strikesAllowed,
    required super.at,
  });

  final double similarity;

  /// Consecutive mismatch count. A single failure may be pose or lighting;
  /// sustained failure is a different person.
  final int strike;
  final int strikesAllowed;

  bool get isCritical => strike >= strikesAllowed;
}

/// No comparison was possible. Carries the reason so the UI can say what
/// went unmeasured instead of showing a reassuring green tick.
final class Unchecked extends VerificationResult {
  const Unchecked({required this.reason, required super.at});

  final UncheckedReason reason;
}

enum UncheckedReason {
  noCamera('No camera feed available'),
  noFaceInFrame('No face detected in frame'),
  noEnrolledProfile('No enrolled face profile to compare against'),
  engineUnavailable('Face recognition engine unavailable'),
  serviceUnreachable('Verification service unreachable');

  const UncheckedReason(this.message);
  final String message;
}
