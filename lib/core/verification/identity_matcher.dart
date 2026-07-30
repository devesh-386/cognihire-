import 'dart:math' as math;

import 'verification_result.dart';

/// Compares face embeddings and decides match / mismatch / unmeasurable.
///
/// ## The threshold, and why it is not 85
///
/// The reference build rescaled raw cosine similarity with
/// `(cos + 1) / 2 * 100` and then required >= 85 to pass. Measured against
/// InsightFace `buffalo_l` embeddings on this project's own test images:
///
/// | comparison                        | raw cosine | rescaled |
/// |-----------------------------------|-----------|----------|
/// | same face, identical image        | 1.00      | 100.0    |
/// | same face, degraded (blur/jpeg)   | 0.91–0.99 | 95.7–99.4|
/// | two different people              | 0.012     | **50.6** |
///
/// Two consequences the original threshold got wrong:
///
/// 1. The rescale compresses everything into a 50–100 band. An impostor scores
///    ~50%, not ~0%. A "similarity" figure shown to a human reader is therefore
///    badly misleading — 50% reads as "half right" when it means "unrelated
///    person". [displayConfidence] exists to correct this for UI.
/// 2. Requiring 85 rescaled means requiring raw cosine >= 0.70, which is far
///    stricter than the ~0.4–0.5 typically used with ArcFace embeddings. The
///    degradation figures above look reassuring but are transforms of a single
///    photo; genuine same-person variation across sessions (different day,
///    pose, expression, camera) is substantially wider. A 0.70 bar would
///    reject real candidates.
///
/// The default here is therefore raw cosine 0.50 (== 75 rescaled), which sits
/// well clear of the ~0.01 impostor baseline while leaving headroom for honest
/// variation.
///
/// This value is a reasoned starting point, NOT a validated one. Calibrating it
/// needs pairs of genuinely separate captures of the same person, which this
/// project does not yet have. Until that exists, treat the threshold as
/// provisional and do not cite a false-accept/false-reject rate anywhere.
class IdentityMatcher {
  const IdentityMatcher({
    this.rawThreshold = 0.50,
    this.strikesAllowed = 3,
  });

  /// Raw cosine similarity required to accept a match.
  final double rawThreshold;

  /// Consecutive mismatches tolerated before the result is critical.
  final int strikesAllowed;

  double get rescaledThreshold => rescale(rawThreshold);

  /// Cosine similarity of two embeddings, in [-1, 1].
  /// Returns null when the inputs cannot be meaningfully compared — callers
  /// must map that to [Unchecked], never to a score.
  static double? cosineSimilarity(List<double> a, List<double> b) {
    if (a.isEmpty || b.isEmpty || a.length != b.length) return null;

    var dot = 0.0;
    var normA = 0.0;
    var normB = 0.0;
    for (var i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      normA += a[i] * a[i];
      normB += b[i] * b[i];
    }
    if (normA == 0 || normB == 0) return null;

    return dot / (math.sqrt(normA) * math.sqrt(normB));
  }

  /// The legacy 0–100 presentation scale, kept for wire compatibility with the
  /// Python backend. Note it floors near 50 for unrelated faces.
  static double rescale(double rawCosine) => (rawCosine + 1) / 2 * 100;

  /// A human-honest 0–100 reading where an unrelated face lands near 0.
  ///
  /// Maps the *usable* cosine band [0, 1] onto [0, 100] and clamps below zero,
  /// so "12%" means "barely related" rather than the misleading "56%" the
  /// legacy scale would print for the same pair.
  static double displayConfidence(double rawCosine) =>
      (rawCosine.clamp(0.0, 1.0)) * 100;

  /// Compare a live embedding against an enrolled one.
  ///
  /// [consecutiveMismatches] is the count *before* this attempt; the caller
  /// owns that state so this class stays pure.
  VerificationResult compare({
    required List<double>? enrolled,
    required List<double>? live,
    required int consecutiveMismatches,
    DateTime? now,
  }) {
    final at = now ?? DateTime.now();

    if (enrolled == null || enrolled.isEmpty) {
      return Unchecked(reason: UncheckedReason.noEnrolledProfile, at: at);
    }
    if (live == null || live.isEmpty) {
      return Unchecked(reason: UncheckedReason.noFaceInFrame, at: at);
    }

    final raw = cosineSimilarity(enrolled, live);
    if (raw == null) {
      return Unchecked(reason: UncheckedReason.engineUnavailable, at: at);
    }

    if (raw >= rawThreshold) {
      return Verified(similarity: rescale(raw), at: at);
    }

    return Mismatch(
      similarity: rescale(raw),
      strike: consecutiveMismatches + 1,
      strikesAllowed: strikesAllowed,
      at: at,
    );
  }
}
