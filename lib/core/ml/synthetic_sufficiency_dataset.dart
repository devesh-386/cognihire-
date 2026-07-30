import 'dart:math' as math;

import '../features/feature_registry.dart';

/// A **synthetic**, ground-truth-known dataset for the evidence-sufficiency
/// target that Phase 3.2's model $f_\theta$ will eventually predict.
///
/// ## Read this before using it anywhere
///
/// This is NOT real candidate data and must never be treated as evidence about
/// any real person. Its entire and only purpose is to prove that the training,
/// calibration, and evaluation *mechanism* is mathematically correct — that a
/// logistic model fit on these examples recovers a signal we planted on
/// purpose, that calibration curves behave, that the pipeline runs end to end —
/// before a single real labelled session exists (Phase 2). It exists for the
/// same reason [PlattScaler.fit] can be unit-tested on synthetic pairs: you can
/// verify the maths against a known answer without waiting for the world.
///
/// The label here is a *manufactured* "sufficient evidence" flag drawn from a
/// documented logistic generative process ([groundTruthWeights] over
/// standardized features, plus [groundTruthBias]). Because the answer is known,
/// a correct multivariate trainer must approximately recover those weights —
/// that recovery is the correctness proof. A trainer that instead latches onto
/// a zero-weight noise feature is provably wrong, and a test can say so.
///
/// [isSynthetic] is always true and there is no constructor that makes it
/// false: nothing downstream can ever mistake this for real data by accident.
class SyntheticSufficiencyDataset {
  const SyntheticSufficiencyDataset({
    required this.examples,
    required this.groundTruthWeights,
    required this.groundTruthBias,
    required Map<String, ({double lo, double hi})> samplingRanges,
  }) : _ranges = samplingRanges;

  final List<SufficiencyExample> examples;

  /// The planted weights, in *standardized* feature space (see [standardize]),
  /// keyed by registry feature name. A trainer that standardizes features the
  /// same way should recover these up to sampling noise. Zero-weight noise
  /// features are deliberately omitted here — their absence is the claim that
  /// they carry no signal.
  final Map<String, double> groundTruthWeights;

  final double groundTruthBias;

  final Map<String, ({double lo, double hi})> _ranges;

  /// Always true. There is intentionally no way to construct a
  /// [SyntheticSufficiencyDataset] that reports false.
  bool get isSynthetic => true;

  /// The exact standardization a trainer must apply to raw feature values to
  /// work in the same space as [groundTruthWeights]: map the feature's sampling
  /// range \[lo, hi] to \[-1, 1], midpoint to 0. Publishing the transform (not
  /// just the data) is what makes weight-recovery a fair, reproducible check.
  double standardize(String name, double raw) {
    final r = rangeFor(name);
    final mid = (r.lo + r.hi) / 2;
    final half = (r.hi - r.lo) / 2;
    return half == 0 ? 0.0 : (raw - mid) / half;
  }

  /// The sampling range recorded for [name] — the interval its raw values were
  /// drawn from, needed to reproduce [standardize] elsewhere (e.g. so a fitted
  /// model can standardize prediction inputs identically). Throws for an
  /// unknown feature rather than guessing a range.
  ({double lo, double hi}) rangeFor(String name) {
    final r = _ranges[name];
    if (r == null) {
      throw ArgumentError('no sampling range recorded for "$name"');
    }
    return r;
  }
}

/// One synthetic example: raw feature values plus the manufactured label and
/// the generative probability it was drawn from (kept for diagnostics — e.g.
/// checking a calibrator's reliability against the true probability).
class SufficiencyExample {
  const SufficiencyExample({
    required this.features,
    required this.sufficient,
    required this.trueProbability,
    required this.group,
  });

  final Map<String, double> features;
  final bool sufficient;
  final double trueProbability;

  /// The synthetic "candidate" this example belongs to. Multiple examples can
  /// share a group, so a grouped train/test split can be tested for leakage
  /// (no candidate appearing on both sides) exactly as a real per-candidate
  /// split must guarantee.
  final String group;
}

/// One signal feature in the generative process: a real registry feature, the
/// range it is sampled over, and its weight in standardized space (0 for a
/// deliberate noise feature).
class _Signal {
  const _Signal(this.name, this.lo, this.hi, this.weight);
  final String name;
  final double lo;
  final double hi;
  final double weight;
}

/// Produces [SyntheticSufficiencyDataset]s from a fixed, documented logistic
/// generative model. Deterministic given a seed, so tests and calibration
/// experiments are reproducible.
class SyntheticSufficiencyGenerator {
  const SyntheticSufficiencyGenerator();

  /// The generative model. Every `name` is a real feature from the registry so
  /// the synthetic vectors are structurally the same shape a real assembler
  /// would produce. Weights are in standardized (\[-1, 1]) space; the sign is
  /// the planted story:
  ///   + more genuine support, verified identity, answered claims, productive
  ///     editing  -> more likely "sufficient"
  ///   - contradictions, sustained identity mismatches, superhuman-fast typing
  ///     -> less likely
  /// The last two entries are weight-0 NOISE: registered features with no
  /// generative influence, present so a trainer can be tested for ignoring
  /// them.
  static const List<_Signal> _model = [
    _Signal('graph.supportsEdgeCount', 0, 10, 1.4),
    _Signal('graph.contradictsEdgeCount', 0, 6, -1.6),
    _Signal('identity.verifiedShareOfMeasured', 0, 1, 1.2),
    _Signal('identity.maxConsecutiveMismatches', 0, 5, -1.0),
    _Signal('session.answeredToOpenedRatio', 0, 1.5, 0.8),
    _Signal('editing.netToGrossRatio', 0, 1, 0.9),
    _Signal('typing.veryFastKeystrokeRate', 0, 0.5, -1.1),
    // --- noise: registered, weightless ---
    _Signal('typing.backspaceRate', 0, 0.4, 0.0),
    _Signal('session.followUpCount', 0, 5, 0.0),
  ];

  static const double _bias = -0.2;

  SyntheticSufficiencyDataset generate({
    required int count,
    required int seed,
    int? groupCount,
  }) {
    if (count <= 0) {
      throw ArgumentError('count must be positive (got $count)');
    }
    // Default: roughly 10 examples per synthetic candidate, at least 2 groups
    // so a grouped split has something to separate.
    final groups = groupCount ?? math.max(2, count ~/ 10);
    if (groups < 1) {
      throw ArgumentError('groupCount must be positive (got $groups)');
    }
    // Fail loudly if the model ever references a feature that isn't registered
    // — a synthetic dataset over phantom features would be a silent lie about
    // what shape real data has.
    for (final s in _model) {
      if (!FeatureRegistry.instance.contains(s.name)) {
        throw StateError('synthetic model references unregistered feature '
            '"${s.name}"');
      }
    }

    final rng = math.Random(seed);
    final examples = <SufficiencyExample>[];

    for (var i = 0; i < count; i++) {
      final features = <String, double>{};
      var logit = _bias;
      for (final s in _model) {
        final raw = s.lo + rng.nextDouble() * (s.hi - s.lo);
        features[s.name] = raw;
        if (s.weight != 0.0) {
          final mid = (s.lo + s.hi) / 2;
          final half = (s.hi - s.lo) / 2;
          final standardized = half == 0 ? 0.0 : (raw - mid) / half;
          logit += s.weight * standardized;
        }
      }
      final p = 1.0 / (1.0 + math.exp(-logit));
      final label = rng.nextDouble() < p;
      examples.add(SufficiencyExample(
        features: features,
        sufficient: label,
        trueProbability: p,
        group: 'candidate-${i % groups}',
      ));
    }

    return SyntheticSufficiencyDataset(
      examples: examples,
      groundTruthWeights: {
        for (final s in _model)
          if (s.weight != 0.0) s.name: s.weight,
      },
      groundTruthBias: _bias,
      samplingRanges: {
        for (final s in _model) s.name: (lo: s.lo, hi: s.hi),
      },
    );
  }
}
