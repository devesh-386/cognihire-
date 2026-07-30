import 'dart:math' as math;

import 'sufficiency_attribution.dart';
import 'synthetic_sufficiency_dataset.dart';

/// A multivariate logistic-regression model for the evidence-sufficiency
/// target of Phase 3.2 — the mechanism that will, once a real Phase 2 dataset
/// exists, estimate the probability that the assembled evidence is sufficient
/// to support a claim.
///
/// ## Mechanism now, validated model later — the same discipline as PlattScaler
///
/// [fitSynthetic] performs real batch gradient-descent logistic regression, so
/// the training code, the standardization, and the prediction path are all
/// genuinely exercised today. What it is *not* is a model you may trust about a
/// real candidate: it has only ever seen [SyntheticSufficiencyDataset] examples
/// drawn from a made-up generative process. That distinction is load-bearing
/// and is carried in the model itself:
///
///   * [trainedOnSyntheticData] is true and [isValidatedOnRealData] is false
///     for anything [fitSynthetic] returns.
///   * There is deliberately no `fitReal` constructor yet — there is no real
///     data to give it. When Phase 2 lands, the honest move is a separate
///     factory that sets [isValidatedOnRealData] only after held-out
///     evaluation, never a silent flip of these flags.
///
/// The proof that the mechanism is correct is external: fit on synthetic data
/// whose weights we planted, then check the recovered weights match their
/// planted signs and rough magnitudes and that noise features stay near zero
/// (see `sufficiency_model_test.dart`). A trainer that cannot recover a known
/// answer cannot be trusted on an unknown one.
class SufficiencyModel {
  const SufficiencyModel._({
    required this._weights,
    required this.bias,
    required this._ranges,
    required this.trainedOnSyntheticData,
    required this.isValidatedOnRealData,
  });

  final Map<String, double> _weights;
  final double bias;
  final Map<String, ({double lo, double hi})> _ranges;

  /// True when the only data this model ever saw was synthetic. A consumer must
  /// check this before showing any output as if it described a real person.
  final bool trainedOnSyntheticData;

  /// Always false for a synthetic fit. Reserved for a future real-data factory
  /// that sets it only after held-out evaluation — never toggled implicitly.
  final bool isValidatedOnRealData;

  /// The learned weight for [name] in standardized feature space, or null if
  /// the model was not trained with that feature.
  double? weightFor(String name) => _weights[name];

  /// Every feature this model was trained on, in the stable order it was fit
  /// in. Nothing outside this set can be reasoned about — a consumer asking
  /// about anything else is asking about a feature the model never saw.
  Iterable<String> get featureNames => _weights.keys;

  /// The raw-value range [name] was fit over, or null if untrained. Exposed
  /// because a value outside it is an extrapolation, and callers that offer
  /// advice (counterfactuals) must be able to say so rather than guess.
  ({double lo, double hi})? rangeFor(String name) => _ranges[name];

  /// [name]'s raw value mapped into the model's standardized space, or null if
  /// untrained. Public so an explanation can be computed in exactly the space
  /// the decision was made in, never a re-derived approximation of it.
  double? standardizeFeature(String name, double raw) =>
      _ranges.containsKey(name) ? _standardize(name, raw) : null;

  /// Probability of "sufficient" for a raw (un-standardized) feature map. A
  /// feature the model was not trained on is ignored; a trained feature missing
  /// from [rawFeatures] contributes its standardized midpoint (0) — i.e. "no
  /// information", never a fabricated extreme.
  double predictProbability(Map<String, double> rawFeatures) {
    var z = bias;
    _weights.forEach((name, w) {
      final raw = rawFeatures[name];
      if (raw == null) return; // missing -> standardized 0 -> no contribution
      z += w * _standardize(name, raw);
    });
    return _sigmoid(z);
  }

  double _standardize(String name, double raw) {
    final r = _ranges[name]!;
    final mid = (r.lo + r.hi) / 2;
    final half = (r.hi - r.lo) / 2;
    return half == 0 ? 0.0 : (raw - mid) / half;
  }

  /// Decompose the prediction for [rawFeatures] into exact per-feature
  /// contributions to the logit. For this linear model the sum of contributions
  /// plus [bias] is exactly the logit behind [predictProbability] — the
  /// explanation is the arithmetic, not a post-hoc surrogate. A trained feature
  /// missing from [rawFeatures] contributes 0 (its standardized midpoint).
  SufficiencyAttribution explain(Map<String, double> rawFeatures) {
    final contributions = <FeatureContribution>[];
    var logit = bias;
    _weights.forEach((name, w) {
      final raw = rawFeatures[name] ?? _midpoint(name);
      final std = _standardize(name, raw);
      final contribution = w * std;
      logit += contribution;
      contributions.add(FeatureContribution(
        feature: name,
        rawValue: raw,
        standardizedValue: std,
        weight: w,
        contribution: contribution,
      ));
    });
    contributions
        .sort((a, b) => b.contribution.abs().compareTo(a.contribution.abs()));
    return SufficiencyAttribution(
      bias: bias,
      logit: logit,
      probability: _sigmoid(logit),
      contributions: contributions,
    );
  }

  double _midpoint(String name) {
    final r = _ranges[name]!;
    return (r.lo + r.hi) / 2;
  }

  /// Fit on a synthetic dataset. Trains over **every** feature present in the
  /// examples — including the deliberate noise features — so that "the trainer
  /// ignores noise" is something a test can actually verify, not something
  /// guaranteed by hiding the noise from it.
  factory SufficiencyModel.fitSynthetic(
    SyntheticSufficiencyDataset dataset, {
    List<SufficiencyExample>? trainOn,
    int iterations = 4000,
    double learningRate = 0.3,
    double l2 = 0.001,
  }) {
    // Fit on the given subset (e.g. a grouped split's train side) when
    // provided, standardizing with the dataset's ranges either way so the
    // transform is identical to what predict() will later apply.
    final examples = trainOn ?? dataset.examples;
    if (examples.isEmpty) {
      throw ArgumentError('cannot fit on an empty dataset');
    }

    // Stable feature order from the first example's keys.
    final featureNames = examples.first.features.keys.toList()..sort();

    // Standardize every example once up front using the dataset's own ranges,
    // so training and later prediction share exactly one transform.
    final X = <List<double>>[];
    final y = <double>[];
    for (final ex in examples) {
      X.add([
        for (final name in featureNames)
          dataset.standardize(name, ex.features[name] ?? 0.0),
      ]);
      y.add(ex.sufficient ? 1.0 : 0.0);
    }

    final n = X.length;
    final d = featureNames.length;
    final w = List<double>.filled(d, 0.0);
    var b = 0.0;

    for (var iter = 0; iter < iterations; iter++) {
      final gradW = List<double>.filled(d, 0.0);
      var gradB = 0.0;
      for (var i = 0; i < n; i++) {
        var z = b;
        for (var j = 0; j < d; j++) {
          z += w[j] * X[i][j];
        }
        final error = _sigmoid(z) - y[i];
        for (var j = 0; j < d; j++) {
          gradW[j] += error * X[i][j];
        }
        gradB += error;
      }
      for (var j = 0; j < d; j++) {
        w[j] -= learningRate * (gradW[j] / n + l2 * w[j]);
      }
      b -= learningRate * (gradB / n);
    }

    return SufficiencyModel._(
      weights: {
        for (var j = 0; j < d; j++) featureNames[j]: w[j],
      },
      bias: b,
      ranges: {
        for (final name in featureNames)
          name: dataset.rangeFor(name),
      },
      trainedOnSyntheticData: true,
      isValidatedOnRealData: false,
    );
  }

  /// The artifact schema this loader understands. Bumped only when the JSON
  /// shape changes; a mismatch is rejected rather than best-effort parsed,
  /// because a silently misread weight is a wrong decision that looks right.
  ///
  /// v2 added an optional `calibration` section — see [TrainedArtifact].
  static const int supportedSchemaVersion = 2;

  /// Load a model fitted by the Python trainer (`service/ml/`), as written to
  /// `assets/ml/sufficiency_model.json` by `python -m ml.export_model`.
  ///
  /// ## Why the training moved out and the scoring did not
  ///
  /// Fitting belongs in Python: scikit-learn's solver is better than the hand-
  /// rolled descent in [fitSynthetic], and validating on real Phase 2 data will
  /// need tooling Dart does not have. Scoring stays here, on-device, for the
  /// same reason the face service does not decide whether two faces match — a
  /// component that returns verdicts is a component that can invent them. This
  /// factory reads coefficients, never a decision: the guards, the refusal, and
  /// the explanation all still run locally against the same arithmetic.
  ///
  /// [fitSynthetic] is retained and still tested. It is the fallback if the
  /// asset is absent, and it is the independent implementation that
  /// `sufficiency_model_export_test.dart` checks the Python fit against.
  ///
  /// The honesty flags are read from the artifact, never assumed. A file that
  /// omits them, or that claims real-data validation without saying it was
  /// trained on something, is rejected.
  factory SufficiencyModel.fromTrainedJson(Map<String, dynamic> json) {
    final version = json['schemaVersion'];
    if (version != supportedSchemaVersion) {
      throw FormatException(
        'unsupported model schemaVersion $version '
        '(this build understands $supportedSchemaVersion)',
      );
    }

    final bias = _requireFinite(json['bias'], 'bias');

    final rawFeatures = json['features'];
    if (rawFeatures is! List || rawFeatures.isEmpty) {
      throw const FormatException('model artifact has no features');
    }

    final weights = <String, double>{};
    final ranges = <String, ({double lo, double hi})>{};
    for (final entry in rawFeatures) {
      if (entry is! Map) {
        throw const FormatException('each feature must be an object');
      }
      final name = entry['name'];
      if (name is! String || name.isEmpty) {
        throw const FormatException('feature entry is missing a name');
      }
      if (weights.containsKey(name)) {
        throw FormatException('feature "$name" appears twice');
      }
      final lo = _requireFinite(entry['lo'], '$name.lo');
      final hi = _requireFinite(entry['hi'], '$name.hi');
      if (!(hi > lo)) {
        // A degenerate range would standardize every value to 0, quietly
        // deleting the feature from the decision. Fail instead.
        throw FormatException('feature "$name" has an empty range [$lo, $hi]');
      }
      weights[name] = _requireFinite(entry['weight'], '$name.weight');
      ranges[name] = (lo: lo, hi: hi);
    }

    final trainedOnSynthetic = json['trainedOnSyntheticData'];
    final validatedOnReal = json['isValidatedOnRealData'];
    if (trainedOnSynthetic is! bool || validatedOnReal is! bool) {
      throw const FormatException(
        'model artifact must declare trainedOnSyntheticData and '
        'isValidatedOnRealData explicitly',
      );
    }
    if (validatedOnReal && trainedOnSynthetic) {
      throw const FormatException(
        'model artifact claims real-data validation while also reporting it '
        'only ever saw synthetic data — one of those is false',
      );
    }

    return SufficiencyModel._(
      weights: weights,
      bias: bias,
      ranges: ranges,
      trainedOnSyntheticData: trainedOnSynthetic,
      isValidatedOnRealData: validatedOnReal,
    );
  }

  static double _requireFinite(Object? value, String field) {
    final d = value is num ? value.toDouble() : null;
    if (d == null || !d.isFinite) {
      throw FormatException('$field must be a finite number (got $value)');
    }
    return d;
  }

  static double _sigmoid(double z) {
    final clamped = z.clamp(-30.0, 30.0);
    return 1.0 / (1.0 + math.exp(-clamped));
  }
}
