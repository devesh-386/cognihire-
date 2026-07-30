import 'sufficiency_attribution.dart';
import 'sufficiency_counterfactual.dart';
import 'sufficiency_model.dart';

/// A rendered, human-readable account of one model decision — Phase 3.4c.
///
/// Every number in here is copied from [SufficiencyAttribution] and
/// [SufficiencyCounterfactual], never recomputed, so the prose and the maths
/// cannot drift apart.
class SufficiencyExplanation {
  const SufficiencyExplanation({
    required this.probability,
    required this.threshold,
    required this.headline,
    required this.drivers,
    required this.driverLines,
    required this.counterfactualLines,
    required this.describesRealPerson,
    required this.caveat,
  });

  final double probability;
  final double threshold;

  /// One sentence stating what the model output was. Deliberately about the
  /// *estimate*, not about a person.
  final String headline;

  /// The contributions the [driverLines] were rendered from, kept so a UI can
  /// lay them out itself instead of parsing prose.
  final List<FeatureContribution> drivers;

  final List<String> driverLines;

  /// Either the feasible single-input moves, or exactly one line saying no
  /// single input reaches the boundary. Never empty, never silently omitted —
  /// "we found nothing" and "we didn't look" must not read the same.
  final List<String> counterfactualLines;

  /// False whenever the model behind this text has only ever seen synthetic
  /// data. A UI must refuse to present the explanation as being about a real
  /// candidate while this is false.
  final bool describesRealPerson;

  /// Non-null exactly when there is something the reader must be told before
  /// believing any of the above.
  final String? caveat;

  /// The whole explanation as one block, caveat last so it is the final thing
  /// read rather than something scrolled past.
  String toPlainText() {
    final parts = <String>[
      headline,
      ...driverLines,
      ...counterfactualLines,
      ?caveat,
    ];
    return parts.join('\n');
  }
}

/// Turns an exact attribution plus its counterfactuals into sentences — the
/// last hop before a human reads the decision, and therefore the easiest place
/// in the pipeline to introduce a claim the maths never made.
///
/// ## The rules this templater holds itself to
///
///   * It describes **what the model weighted**, never what a person did. There
///     is no "because", no "the candidate", no verdict vocabulary. A feature
///     pushed a number; that is the entire claim.
///   * Feature names are humanised **mechanically** (prefix + camelCase split).
///     Hand-written friendly labels would be a place to smuggle in an
///     interpretation the feature does not actually carry.
///   * A model that has only seen synthetic data always renders a caveat, and
///     [SufficiencyExplanation.describesRealPerson] is false. Neither is
///     optional or suppressible by a caller.
class ExplanationTemplater {
  const ExplanationTemplater();

  static const String _syntheticCaveat =
      'Caveat: this model was trained only on synthetic data and has never '
      'been validated on real sessions. The reasoning above shows how the '
      'mechanism works — it is not a finding about any real person.';

  /// Split a registry feature name into readable words without adding meaning:
  /// `graph.supportsEdgeCount` -> `graph: supports edge count`.
  static String humanise(String feature) {
    final dot = feature.indexOf('.');
    final group = dot == -1 ? null : feature.substring(0, dot);
    final leaf = dot == -1 ? feature : feature.substring(dot + 1);
    final words = leaf
        .replaceAllMapped(RegExp(r'(?<=[a-z0-9])([A-Z])'),
            (m) => ' ${m.group(1)!.toLowerCase()}')
        .toLowerCase();
    return group == null ? words : '$group: $words';
  }

  static String _num(double v) {
    if (v == v.roundToDouble() && v.abs() < 1e6) return v.round().toString();
    return v.toStringAsFixed(2);
  }

  /// Render the decision for [rawFeatures] under [model].
  ///
  /// [topN] caps how many drivers are named; asking for more than exist simply
  /// names them all rather than padding the list out.
  SufficiencyExplanation render({
    required SufficiencyModel model,
    required Map<String, double> rawFeatures,
    double threshold = 0.5,
    int topN = 3,
  }) {
    final attribution = model.explain(rawFeatures);
    final drivers = attribution.topContributors(topN);
    final above = attribution.probability >= threshold;

    final headline = 'Model estimate: ${(attribution.probability * 100).round()}% '
        'likely sufficient — ${above ? 'at or above' : 'below'} the '
        '${(threshold * 100).round()}% decision line.';

    final driverLines = [
      for (final c in drivers)
        '${humanise(c.feature)} (${_num(c.rawValue)}) pushed '
            '${c.pushesTowardSufficient ? 'toward' : 'away from'} sufficient '
            'by ${c.contribution.abs().toStringAsFixed(2)}.',
    ];

    final feasible =
        CounterfactualSearch.singleFeature(model, rawFeatures,
                threshold: threshold)
            .where((c) => c.isFeasible)
            .take(2)
            .toList();

    final counterfactualLines = feasible.isEmpty
        ? const [
            'No single input, kept within the range this model was fit over, '
                'reaches the decision line on its own.'
          ]
        : [
            for (final cf in feasible)
              'Holding every other input fixed, '
                  '${humanise(cf.feature)} would reach the decision line at '
                  '${_num(cf.requiredValue)} '
                  '(${cf.requiresIncrease ? 'up' : 'down'} from '
                  '${_num(cf.currentValue)}).',
          ];

    return SufficiencyExplanation(
      probability: attribution.probability,
      threshold: threshold,
      headline: headline,
      drivers: drivers,
      driverLines: driverLines,
      counterfactualLines: counterfactualLines,
      describesRealPerson: model.isValidatedOnRealData,
      caveat: model.trainedOnSyntheticData ? _syntheticCaveat : null,
    );
  }
}
