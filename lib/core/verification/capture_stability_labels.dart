import 'identity_matcher.dart';

/// Self-supervised labels for whether a captured frame's embedding was
/// "stable" — the ground truth `ML_REDESIGN.md` §2.1/§4.11 uses to train the
/// capture-quality head, requiring zero human annotation.
///
/// ## The definition, precisely
///
/// A frame's embedding is stable if it stays close (by cosine similarity) to
/// its temporal neighbours — frames captured moments before and after it, of
/// what should be the same face under near-identical conditions. A frame that
/// diverges sharply from its neighbours was probably a bad capture (motion
/// blur, a partial occlusion, a lighting flicker) even though nothing about
/// that single frame in isolation says so. This sidesteps needing a human to
/// look at each frame and judge quality — the neighbouring frames are the
/// judges.
///
/// [window] frames are taken from each side where available; a label is
/// `null` — not `false` — when fewer than [minNeighbours] neighbours exist to
/// judge from (typically the first and last few frames of a short sequence),
/// because "insufficient evidence" and "measured as unstable" are different
/// facts and must not collapse into one.
List<bool?> selfSupervisedStabilityLabels({
  required List<List<double>> embeddings,
  int window = 3,
  double stableThreshold = 0.9,
  int minNeighbours = 2,
}) {
  if (embeddings.isEmpty) return const [];

  final labels = <bool?>[];
  for (var i = 0; i < embeddings.length; i++) {
    final neighbourIndices = <int>[
      for (var j = i - window; j <= i + window; j++)
        if (j != i && j >= 0 && j < embeddings.length) j,
    ];

    if (neighbourIndices.length < minNeighbours) {
      labels.add(null);
      continue;
    }

    var total = 0.0;
    var measured = 0;
    for (final j in neighbourIndices) {
      final sim = IdentityMatcher.cosineSimilarity(embeddings[i], embeddings[j]);
      if (sim != null) {
        total += sim;
        measured++;
      }
    }

    if (measured < minNeighbours) {
      labels.add(null);
      continue;
    }

    labels.add(total / measured >= stableThreshold);
  }
  return labels;
}
