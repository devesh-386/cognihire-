import 'package:cognihire/core/ml/conformal_sufficiency.dart';
import 'package:cognihire/core/ml/decision_guards.dart';
import 'package:cognihire/core/ml/explanation_templater.dart';
import 'package:cognihire/core/ml/sufficiency_model.dart';
import 'package:cognihire/core/ml/synthetic_sufficiency_dataset.dart';
import 'package:flutter_test/flutter_test.dart';

/// Phase 3.4d — the guard suite.
///
/// Every other test in `lib/core/ml` asks "is the maths right?". These ask the
/// different and harder question: "could this be *presented* wrongly even
/// though the maths is right?" Each guard encodes one way an honest pipeline
/// can still produce a dishonest screen.
void main() {
  late SufficiencyModel model;
  late Map<String, double> subject;

  setUp(() {
    final dataset =
        const SyntheticSufficiencyGenerator().generate(count: 400, seed: 3);
    model = SufficiencyModel.fitSynthetic(dataset);
    subject = {
      'graph.supportsEdgeCount': 5.0,
      'graph.contradictsEdgeCount': 3.0,
      'identity.verifiedShareOfMeasured': 0.5,
      'identity.maxConsecutiveMismatches': 2.0,
      'session.answeredToOpenedRatio': 0.75,
      'editing.netToGrossRatio': 0.5,
      'typing.veryFastKeystrokeRate': 0.25,
      'typing.backspaceRate': 0.2,
      'session.followUpCount': 2.0,
    };
  });

  DecisionUnderReview review({
    Map<String, double>? features,
    bool presentedAsAboutRealPerson = false,
    bool committedLabelShown = false,
    ConformalPrediction? conformal,
    SufficiencyExplanation? explanation,
  }) {
    final f = features ?? subject;
    return DecisionUnderReview(
      model: model,
      rawFeatures: f,
      explanation: explanation ??
          const ExplanationTemplater().render(model: model, rawFeatures: f),
      conformal: conformal,
      presentedAsAboutRealPerson: presentedAsAboutRealPerson,
      committedLabelShown: committedLabelShown,
    );
  }

  test('a well-formed synthetic decision passes every guard', () {
    expect(DecisionGuards.check(review()), isEmpty);
  });

  test('an unvalidated model presented as being about a real person is a '
      'blocking violation', () {
    final v = DecisionGuards.check(review(presentedAsAboutRealPerson: true));
    expect(v.map((x) => x.guard), contains('unvalidated-model-as-real'));
    expect(v.firstWhere((x) => x.guard == 'unvalidated-model-as-real').isBlocking,
        isTrue);
  });

  test('a synthetic model whose explanation lost its caveat is caught', () {
    final stripped = SufficiencyExplanation(
      probability: model.predictProbability(subject),
      threshold: 0.5,
      headline: 'Model estimate: 50% likely sufficient.',
      drivers: const [],
      driverLines: const [],
      counterfactualLines: const ['x'],
      describesRealPerson: false,
      caveat: null,
    );
    final v = DecisionGuards.check(review(explanation: stripped));
    expect(v.map((x) => x.guard), contains('missing-synthetic-caveat'));
  });

  test('showing a committed label while the conformal set abstains is a '
      'blocking violation', () {
    final conformal = ConformalSufficiency.fit(
      scoresSufficient: const [0.5, 0.5, 0.5, 0.5, 0.5, 0.5],
      labels: const [true, false, true, false, true, false],
      alpha: 0.05,
    );
    final prediction = conformal.predict(0.5);
    expect(prediction.isAbstain, isTrue,
        reason: 'fixture must actually abstain for this guard to be tested');

    final v = DecisionGuards.check(
        review(conformal: prediction, committedLabelShown: true));
    final hit = v.firstWhere((x) => x.guard == 'abstain-overridden');
    expect(hit.isBlocking, isTrue);
  });

  test('an explanation whose probability disagrees with the model is caught', () {
    final drifted = SufficiencyExplanation(
      probability: model.predictProbability(subject) + 0.2,
      threshold: 0.5,
      headline: 'Model estimate: 99% likely sufficient.',
      drivers: const [],
      driverLines: const [],
      counterfactualLines: const ['x'],
      describesRealPerson: false,
      caveat: 'synthetic',
    );
    expect(DecisionGuards.check(review(explanation: drifted)).map((x) => x.guard),
        contains('explanation-model-mismatch'));
  });

  test('a feature the model never saw is reported, not silently ignored', () {
    final extra = Map<String, double>.from(subject)
      ..['not.aRealFeature'] = 1.0;
    final v = DecisionGuards.check(review(features: extra));
    final hit = v.firstWhere((x) => x.guard == 'unknown-feature');
    expect(hit.detail, contains('not.aRealFeature'));
    expect(hit.isBlocking, isFalse,
        reason: 'an ignored extra input is misleading, not unsafe');
  });

  test('an input outside the range the model was fit over is reported', () {
    final wild = Map<String, double>.from(subject)
      ..['graph.supportsEdgeCount'] = 500.0;
    final v = DecisionGuards.check(review(features: wild));
    expect(v.map((x) => x.guard), contains('extrapolated-input'));
  });

  test('a decision with no measured evidence at all is blocked', () {
    final v = DecisionGuards.check(review(features: const {}));
    final hit = v.firstWhere((x) => x.guard == 'no-evidence');
    expect(hit.isBlocking, isTrue,
        reason: 'with every feature absent the output is just the bias — that '
            'is not a measurement of anything');
  });

  test('violations are ordered blocking-first', () {
    final v = DecisionGuards.check(review(
      features: const {},
      presentedAsAboutRealPerson: true,
    ));
    expect(v.length, greaterThan(1));
    var seenNonBlocking = false;
    for (final x in v) {
      if (!x.isBlocking) seenNonBlocking = true;
      if (seenNonBlocking) expect(x.isBlocking, isFalse);
    }
  });

  test('isSafeToPresent is exactly "no blocking violation"', () {
    expect(DecisionGuards.isSafeToPresent(review()), isTrue);
    expect(
        DecisionGuards.isSafeToPresent(review(presentedAsAboutRealPerson: true)),
        isFalse);
  });
}
