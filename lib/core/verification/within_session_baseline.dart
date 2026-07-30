import 'dart:math' as math;

/// The candidate's own self-similarity distribution within one session — the
/// signal `ML_REDESIGN.md` §4.2 calls "within-session self-referential
/// authorship consistency" applied to identity rather than typing.
///
/// ## Why self-similarity, not a population threshold
///
/// A fixed cosine threshold (see [IdentityMatcher]) compares every candidate
/// against the same fixed bar, calibrated once on whatever data existed at
/// the time. A candidate's own repeated captures within a session — same
/// lighting, same camera, same person by construction if enrolment was
/// genuine — form a tighter, session-specific distribution. A live capture
/// that falls far outside *that* candidate's own established spread is a
/// stronger local signal than "did it clear the population threshold", and it
/// adapts automatically to session-specific conditions no fixed threshold
/// can see in advance.
///
/// This class computes only descriptive statistics over similarity scores
/// already produced elsewhere (by [IdentityMatcher.cosineSimilarity] against
/// the enrolled reference) — it does not compare embeddings itself.
class WithinSessionBaseline {
  const WithinSessionBaseline._({
    required this.mean,
    required this.std,
    required this.min,
    required this.max,
    required this.sampleCount,
  });

  final double mean;
  final double std;
  final double min;
  final double max;
  final int sampleCount;

  /// Build a baseline from this session's similarity scores so far. Returns
  /// null with fewer than two samples — a spread cannot be established from a
  /// single point, and pretending otherwise would let one capture (which
  /// could itself be the anomaly) define its own consistency check.
  static WithinSessionBaseline? from(List<double> similarities) {
    if (similarities.length < 2) return null;

    final mean =
        similarities.reduce((a, b) => a + b) / similarities.length;
    final variance = similarities
            .map((s) => (s - mean) * (s - mean))
            .reduce((a, b) => a + b) /
        similarities.length;

    return WithinSessionBaseline._(
      mean: mean,
      std: math.sqrt(variance),
      min: similarities.reduce(math.min),
      max: similarities.reduce(math.max),
      sampleCount: similarities.length,
    );
  }

  /// Whether [score] falls within a reasonable spread of this baseline.
  ///
  /// Uses a fixed 3-sigma band when [std] is nonzero; when every prior
  /// capture scored identically ([std] == 0, e.g. only two samples that
  /// happened to match), falls back to an absolute tolerance around the mean
  /// rather than requiring exact equality forever after.
  bool isConsistent(double score, {double sigmaBand = 3.0, double floorBand = 0.15}) {
    final band = std > 0 ? sigmaBand * std : floorBand;
    return (score - mean).abs() <= band;
  }
}
