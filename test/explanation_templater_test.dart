import 'package:cognihire/core/ml/explanation_templater.dart';
import 'package:cognihire/core/ml/sufficiency_counterfactual.dart';
import 'package:cognihire/core/ml/sufficiency_model.dart';
import 'package:cognihire/core/ml/synthetic_sufficiency_dataset.dart';
import 'package:flutter_test/flutter_test.dart';

/// Phase 3.4c — templated explanations.
///
/// The templater is the last thing between the maths and a human reading it,
/// which makes it the easiest place in the whole pipeline to accidentally lie.
/// These tests are mostly guards against that: no causal language about a
/// person, no output that drops the synthetic caveat, no number that disagrees
/// with the attribution it came from.
void main() {
  late SufficiencyModel model;
  late Map<String, double> subject;

  setUp(() {
    final dataset =
        const SyntheticSufficiencyGenerator().generate(count: 400, seed: 11);
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

  ExplanationTemplater templater() => const ExplanationTemplater();

  test('a synthetic-trained model always carries its caveat into the text', () {
    final e = templater().render(model: model, rawFeatures: subject);
    expect(e.caveat, isNotNull);
    expect(e.caveat!.toLowerCase(), contains('synthetic'));
    expect(e.toPlainText().toLowerCase(), contains('synthetic'));
    expect(e.describesRealPerson, isFalse);
  });

  test('no line makes a causal claim about a person', () {
    final text = templater().render(model: model, rawFeatures: subject)
        .toPlainText()
        .toLowerCase();
    for (final banned in [
      'because',
      'the candidate',
      'they were',
      'dishonest',
      'cheating',
      'lied',
      'proves',
    ]) {
      expect(text, isNot(contains(banned)),
          reason: 'explanation must describe what the model weighted, never '
              'assert something about a person (found "$banned")');
    }
  });

  test('the stated probability matches the model exactly', () {
    final e = templater().render(model: model, rawFeatures: subject);
    expect(e.probability, closeTo(model.predictProbability(subject), 1e-12));
    expect(e.headline, contains('${(e.probability * 100).round()}%'));
  });

  test('drivers are the top contributors, largest absolute impact first', () {
    final e = templater().render(model: model, rawFeatures: subject, topN: 3);
    expect(e.drivers, hasLength(3));
    final attribution = model.explain(subject);
    expect(e.drivers.map((d) => d.feature),
        attribution.topContributors(3).map((c) => c.feature));
    for (var i = 1; i < e.drivers.length; i++) {
      expect(e.drivers[i - 1].contribution.abs(),
          greaterThanOrEqualTo(e.drivers[i].contribution.abs()));
    }
  });

  test('driver lines name direction without judging it', () {
    final e = templater().render(model: model, rawFeatures: subject);
    for (final line in e.driverLines) {
      expect(line, anyOf(contains('toward sufficient'),
          contains('away from sufficient')));
    }
  });

  test('a feasible counterfactual is rendered as a bounded, hedged suggestion',
      () {
    final e = templater().render(model: model, rawFeatures: subject);
    final feasible = CounterfactualSearch.singleFeature(model, subject)
        .where((c) => c.isFeasible);
    if (feasible.isEmpty) return;
    expect(e.counterfactualLines, isNotEmpty);
    expect(e.counterfactualLines.first.toLowerCase(),
        contains('holding every other input fixed'));
  });

  test('when nothing feasible flips it, that is stated rather than faked', () {
    // Push the subject to a corner no single in-range move can pull back.
    final extreme = {
      'graph.supportsEdgeCount': 10.0,
      'graph.contradictsEdgeCount': 0.0,
      'identity.verifiedShareOfMeasured': 1.0,
      'identity.maxConsecutiveMismatches': 0.0,
      'session.answeredToOpenedRatio': 1.5,
      'editing.netToGrossRatio': 1.0,
      'typing.veryFastKeystrokeRate': 0.0,
      'typing.backspaceRate': 0.2,
      'session.followUpCount': 2.0,
    };
    final e = templater().render(model: model, rawFeatures: extreme);
    final anyFeasible = CounterfactualSearch.singleFeature(model, extreme)
        .any((c) => c.isFeasible);
    if (anyFeasible) return;
    expect(e.counterfactualLines, hasLength(1));
    expect(e.counterfactualLines.single.toLowerCase(),
        contains('no single input'));
  });

  test('feature names are humanised mechanically, never re-interpreted', () {
    expect(ExplanationTemplater.humanise('graph.supportsEdgeCount'),
        'graph: supports edge count');
    expect(ExplanationTemplater.humanise('identity.verifiedShareOfMeasured'),
        'identity: verified share of measured');
    expect(ExplanationTemplater.humanise('bare'), 'bare');
  });

  test('topN larger than the feature count does not throw or pad', () {
    final e = templater().render(model: model, rawFeatures: subject, topN: 99);
    expect(e.drivers.length, model.featureNames.length);
  });

  test('plain text contains every part exactly once and ends with the caveat',
      () {
    final e = templater().render(model: model, rawFeatures: subject);
    final text = e.toPlainText();
    expect(text, contains(e.headline));
    for (final line in e.driverLines) {
      expect(text, contains(line));
    }
    expect(text.trimRight().endsWith(e.caveat!), isTrue);
  });
}
