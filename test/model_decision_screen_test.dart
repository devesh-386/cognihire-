/// Widget tests for the reviewer screen — Phase 3.5.
///
/// Same reasoning as `screens_widget_test.dart`: pure-Dart tests are blind to a
/// screen that throws on build. These additionally check the one behaviour that
/// makes this screen different from a report view — that a blocking guard
/// violation replaces the decision rather than sitting next to it.
library;

import 'package:cognihire/core/design/app_theme.dart';
import 'package:cognihire/core/ml/conformal_sufficiency.dart';
import 'package:cognihire/core/ml/decision_guards.dart';
import 'package:cognihire/core/ml/explanation_templater.dart';
import 'package:cognihire/core/ml/sufficiency_model.dart';
import 'package:cognihire/core/ml/synthetic_sufficiency_dataset.dart';
import 'package:cognihire/features/reviewer/model_decision_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late SufficiencyModel model;
  late Map<String, double> subject;

  setUp(() {
    final dataset =
        const SyntheticSufficiencyGenerator().generate(count: 300, seed: 19);
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
  }) {
    final f = features ?? subject;
    return DecisionUnderReview(
      model: model,
      rawFeatures: f,
      explanation:
          const ExplanationTemplater().render(model: model, rawFeatures: f),
      conformal: conformal,
      presentedAsAboutRealPerson: presentedAsAboutRealPerson,
      committedLabelShown: committedLabelShown,
    );
  }

  Future<void> pump(WidgetTester tester, DecisionUnderReview d,
      {String? claimText}) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      home: ModelDecisionScreen(decision: d, claimText: claimText),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('renders a clean decision with drivers and the caveat',
      (tester) async {
    await pump(tester, review(), claimText: 'Built a distributed cache');

    expect(find.text('Model decision'), findsOneWidget);
    expect(find.textContaining('Built a distributed cache'), findsOneWidget);
    expect(find.textContaining('Model estimate:'), findsOneWidget);
    expect(find.text('What the model weighted'), findsOneWidget);
    expect(find.text('What would have had to differ'), findsOneWidget);
    // The caveat sits below the fold by design — it is the last thing read,
    // not the first. Assert it is genuinely reachable rather than assuming it.
    await tester.scrollUntilVisible(
        find.text('Not a finding about a real person'), 200,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('Not a finding about a real person'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a blocking violation replaces the decision entirely',
      (tester) async {
    await pump(tester, review(presentedAsAboutRealPerson: true));

    expect(find.text('This decision is not shown'), findsOneWidget);
    expect(find.text('unvalidated-model-as-real'), findsOneWidget);
    // The decision itself must be absent, not merely de-emphasised.
    expect(find.textContaining('Model estimate:'), findsNothing);
    expect(find.text('What the model weighted'), findsNothing);
  });

  testWidgets('a non-blocking violation renders beside the decision',
      (tester) async {
    final extra = Map<String, double>.from(subject)..['not.aReal'] = 1.0;
    await pump(tester, review(features: extra));

    expect(find.textContaining('Model estimate:'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Worth knowing'), 200,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('Worth knowing'), findsOneWidget);
    expect(find.text('unknown-feature'), findsOneWidget);
  });

  testWidgets('an abstaining conformal set is shown as a result, not an error',
      (tester) async {
    final conformal = ConformalSufficiency.fit(
      scoresSufficient: const [0.5, 0.5, 0.5, 0.5, 0.5, 0.5],
      labels: const [true, false, true, false, true, false],
      alpha: 0.05,
    );
    final prediction = conformal.predict(0.5);
    expect(prediction.isAbstain, isTrue);

    await pump(tester, review(conformal: prediction));
    expect(find.text('No answer at this confidence level'), findsOneWidget);
    expect(find.textContaining('Abstaining is a result'), findsOneWidget);
  });

  testWidgets('renders in dark theme without throwing', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.dark,
      home: ModelDecisionScreen(decision: review()),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow viewport does not overflow', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await pump(tester, review());
    expect(tester.takeException(), isNull);
  });
}
