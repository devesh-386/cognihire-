import 'conformal_sufficiency.dart';
import 'explanation_templater.dart';
import 'sufficiency_model.dart';

/// Everything a guard needs to judge one decision *as it is about to be shown*.
///
/// The two boolean fields are the point of this class: they are claims the
/// **caller** is making about how the decision will be presented, not facts the
/// model can know. A guard suite that only ever sees the maths cannot catch a
/// screen that renders a correct number under a wrong heading.
class DecisionUnderReview {
  const DecisionUnderReview({
    required this.model,
    required this.rawFeatures,
    required this.explanation,
    this.conformal,
    this.presentedAsAboutRealPerson = false,
    this.committedLabelShown = false,
  });

  final SufficiencyModel model;
  final Map<String, double> rawFeatures;
  final SufficiencyExplanation explanation;

  /// The conformal set for this decision, when one was computed. Null means the
  /// caller never ran conformal prediction — which is not itself a violation,
  /// but does mean the abstain guard has nothing to check.
  final ConformalPrediction? conformal;

  /// True when the surface showing this decision frames it as a finding about
  /// an actual person, rather than a demonstration of the mechanism.
  final bool presentedAsAboutRealPerson;

  /// True when the surface shows a single committed answer ("sufficient" /
  /// "not sufficient") rather than an abstention or a set.
  final bool committedLabelShown;
}

/// One way this decision would mislead the person reading it.
class GuardViolation {
  const GuardViolation({
    required this.guard,
    required this.detail,
    required this.isBlocking,
  });

  /// Stable kebab-case id, safe to branch on and to log.
  final String guard;

  final String detail;

  /// True when showing the decision anyway would state something false. False
  /// when it would merely be incomplete or confusing.
  final bool isBlocking;

  @override
  String toString() =>
      '${isBlocking ? 'BLOCK' : 'WARN'} $guard: $detail';
}

/// Phase 3.4d — adversarial guards over a *presented* decision.
///
/// ## Why this exists separately from the tests
///
/// The rest of `lib/core/ml` proves the arithmetic. None of it can stop a
/// caller from putting a mathematically perfect number under the heading "this
/// candidate is not credible" — and that failure would ship with every test
/// green. These guards are the runtime check for that class of failure, which
/// is why they take a [DecisionUnderReview] (including how it will be framed)
/// rather than a model and a feature map.
///
/// Blocking vs warning is a deliberate distinction: blocking means presenting
/// the decision would assert something untrue, and the caller must not proceed.
/// A warning means the presentation is incomplete or could mislead, and the
/// caller should say more — but nothing shown is false.
class DecisionGuards {
  const DecisionGuards._();

  static const double _probabilityTolerance = 1e-9;

  /// Every violation, blocking ones first. An empty list means every guard
  /// passed — not that no guard ran.
  static List<GuardViolation> check(DecisionUnderReview d) {
    final out = <GuardViolation>[];

    if (d.presentedAsAboutRealPerson && !d.model.isValidatedOnRealData) {
      out.add(const GuardViolation(
        guard: 'unvalidated-model-as-real',
        detail: 'the model has never been validated on real data, so its '
            'output cannot be framed as a finding about a real person',
        isBlocking: true,
      ));
    }

    if (d.model.trainedOnSyntheticData && d.explanation.caveat == null) {
      out.add(const GuardViolation(
        guard: 'missing-synthetic-caveat',
        detail: 'a synthetic-trained model produced an explanation carrying no '
            'caveat; the reader would have no way to know',
        isBlocking: true,
      ));
    }

    final conformal = d.conformal;
    if (conformal != null && conformal.isAbstain && d.committedLabelShown) {
      out.add(const GuardViolation(
        guard: 'abstain-overridden',
        detail: 'the conformal set abstains at this confidence level, but a '
            'single committed label is being shown as if it were decided',
        isBlocking: true,
      ));
    }

    // An empty (or wholly unrecognised) feature map means the logit is just the
    // bias: a constant, identical for everyone, describing nobody.
    final known =
        d.rawFeatures.keys.where((k) => d.model.rangeFor(k) != null).toList();
    if (known.isEmpty) {
      out.add(const GuardViolation(
        guard: 'no-evidence',
        detail: 'no feature the model was trained on is present, so the output '
            'is the model bias alone and measures nothing',
        isBlocking: true,
      ));
    }

    final modelProbability = d.model.predictProbability(d.rawFeatures);
    if ((d.explanation.probability - modelProbability).abs() >
        _probabilityTolerance) {
      out.add(GuardViolation(
        guard: 'explanation-model-mismatch',
        detail: 'the explanation states ${d.explanation.probability} but the '
            'model returns $modelProbability for these inputs',
        isBlocking: true,
      ));
    }

    if (d.explanation.probability < 0.0 || d.explanation.probability > 1.0) {
      out.add(GuardViolation(
        guard: 'probability-out-of-range',
        detail: '${d.explanation.probability} is not a probability',
        isBlocking: true,
      ));
    }

    final unknown = d.rawFeatures.keys
        .where((k) => d.model.rangeFor(k) == null)
        .toList()
      ..sort();
    if (unknown.isNotEmpty) {
      out.add(GuardViolation(
        guard: 'unknown-feature',
        detail: 'supplied but never seen in training, so silently ignored: '
            '${unknown.join(', ')}',
        isBlocking: false,
      ));
    }

    final extrapolated = <String>[];
    for (final entry in d.rawFeatures.entries) {
      final range = d.model.rangeFor(entry.key);
      if (range == null) continue;
      if (entry.value < range.lo - 1e-9 || entry.value > range.hi + 1e-9) {
        extrapolated.add('${entry.key}=${entry.value} outside '
            '[${range.lo}, ${range.hi}]');
      }
    }
    if (extrapolated.isNotEmpty) {
      extrapolated.sort();
      out.add(GuardViolation(
        guard: 'extrapolated-input',
        detail: 'outside the range the model was fit over, so its weight there '
            'is an extrapolation: ${extrapolated.join('; ')}',
        isBlocking: false,
      ));
    }

    // Stable order: blocking first, then by guard id, so a caller rendering the
    // list gets the same sequence every run.
    out.sort((a, b) {
      if (a.isBlocking != b.isBlocking) return a.isBlocking ? -1 : 1;
      return a.guard.compareTo(b.guard);
    });
    return out;
  }

  /// True when nothing in [check] would make the presentation state something
  /// false. Warnings do not make a decision unsafe — they make it incomplete.
  static bool isSafeToPresent(DecisionUnderReview d) =>
      !check(d).any((v) => v.isBlocking);
}
