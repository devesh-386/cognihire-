import 'dart:convert';
import 'dart:io';

import 'package:cognihire/core/features/feature_registry.dart';
import 'package:cognihire/core/ml/grouped_split.dart';
import 'package:cognihire/core/ml/isotonic_calibrator.dart';
import 'package:cognihire/core/ml/sufficiency_model.dart';
import 'package:cognihire/core/ml/synthetic_sufficiency_dataset.dart';
import 'package:cognihire/core/ml/trained_artifact.dart';
import 'package:flutter_test/flutter_test.dart';

/// The seam between the Python trainer (`service/ml/`) and the Dart scorer.
///
/// Training moved to Python because scikit-learn fits better than a hand-rolled
/// gradient descent and because real Phase 2 validation will need real tooling.
/// Scoring stayed in Dart because a component that returns verdicts is a
/// component that can invent them. That split is only safe if the handoff is
/// checked, and this file is the check: the artifact must parse, must describe
/// features that actually exist, must carry its honesty flags, and — the part
/// that matters most — must agree with Dart's own independent fit.
///
/// Two implementations of the same maths, agreeing on data whose answer we
/// planted, is a much stronger statement than either one passing alone.
void main() {
  final artifact = File(TrainedArtifact.assetPath);

  group('the exported artifact', () {
    late Map<String, dynamic> json;
    late SufficiencyModel model;

    setUpAll(() {
      expect(
        artifact.existsSync(),
        isTrue,
        reason: 'run: cd service && python -m ml.export_model '
            '--out ../assets/ml/sufficiency_model.json',
      );
      json = jsonDecode(artifact.readAsStringSync()) as Map<String, dynamic>;
      model = SufficiencyModel.fromTrainedJson(json);
    });

    test('loads and reports it has never seen a real person', () {
      expect(model.trainedOnSyntheticData, isTrue);
      expect(model.isValidatedOnRealData, isFalse);
    });

    test('every feature it scores on is actually registered', () {
      // The Python generator cannot see the Dart FeatureRegistry, so this is
      // where a phantom feature would be caught. A model weighting a feature
      // the assembler never produces would silently score every real candidate
      // at that feature's midpoint.
      for (final name in model.featureNames) {
        expect(
          FeatureRegistry.instance.contains(name),
          isTrue,
          reason: 'exported model references unregistered feature "$name"',
        );
      }
    });

    test('every feature has a usable, non-degenerate range', () {
      for (final name in model.featureNames) {
        final r = model.rangeFor(name)!;
        expect(r.hi, greaterThan(r.lo));
      }
    });

    test('probabilities stay in [0,1] across the whole fitted range', () {
      for (final name in model.featureNames) {
        final r = model.rangeFor(name)!;
        for (final v in [r.lo, (r.lo + r.hi) / 2, r.hi]) {
          final p = model.predictProbability({name: v});
          expect(p, inInclusiveRange(0.0, 1.0));
          expect(p.isNaN, isFalse);
        }
      }
    });

    test('the attribution is exactly the arithmetic behind the probability',
        () {
      final mid = {
        for (final n in model.featureNames)
          n: (model.rangeFor(n)!.lo + model.rangeFor(n)!.hi) / 2,
      };
      final a = model.explain(mid);
      final summed = a.contributions.fold<double>(
        model.bias,
        (acc, c) => acc + c.contribution,
      );
      expect(a.logit, closeTo(summed, 1e-12));
      expect(a.probability, closeTo(model.predictProbability(mid), 1e-12));
    });

    test('it agrees with an independent Dart fit on the same generative process',
        () {
      // Not a bit-for-bit comparison: the two trainers use different solvers
      // and different RNG streams, so identical numbers would be suspicious
      // rather than reassuring. What must hold is that both recovered the same
      // story — same signs, similar magnitudes, noise near zero in both.
      const gen = SyntheticSufficiencyGenerator();
      final ds = gen.generate(count: 6000, seed: 100, groupCount: 300);
      final split = GroupedSplit.split(
        ds.examples,
        trainFraction: 0.7,
        seed: 100,
        groupOf: (e) => e.group,
      );
      final dartModel = SufficiencyModel.fitSynthetic(ds, trainOn: split.train);

      for (final name in model.featureNames) {
        final py = model.weightFor(name)!;
        final dart = dartModel.weightFor(name)!;
        final planted = ds.groundTruthWeights[name];

        if (planted == null) {
          // A noise feature: both implementations must have found nothing.
          expect(py.abs(), lessThan(0.15), reason: 'python weighted noise $name');
          expect(dart.abs(), lessThan(0.15), reason: 'dart weighted noise $name');
        } else {
          expect(py * dart, greaterThan(0),
              reason: '$name: implementations disagree on sign');
          expect((py - dart).abs(), lessThan(0.35),
              reason: '$name: python $py vs dart $dart');
        }
      }
    });
  });

  group('the calibration section', () {
    /// A calibrator is embedded only when the trainer measures it improving
    /// held-out ECE. On the current synthetic data it does not — a logistic fit
    /// on a logistic process is already near-calibrated — so the shipped
    /// artifact has none. These tests therefore cover both branches: what the
    /// app does today, and what it must do the day one is earned.
    Map<String, dynamic> withCalibration(Map<String, dynamic> blocks) => {
          'schemaVersion': SufficiencyModel.supportedSchemaVersion,
          'trainedOnSyntheticData': true,
          'isValidatedOnRealData': false,
          'bias': 0.0,
          'features': [
            {
              'name': 'graph.supportsEdgeCount',
              'weight': 2.0,
              'lo': 0.0,
              'hi': 10.0,
            },
          ],
          'calibration': {
            'method': 'isotonic',
            'representation': 'pavaBlocks',
            ...blocks,
          },
        };

    test('the shipped artifact has none, and says so rather than pretending',
        () {
      final loaded = TrainedArtifact.fromJsonString(artifact.readAsStringSync());
      expect(
        loaded.isCalibrated,
        isFalse,
        reason: 'if this fails the trainer started shipping a calibrator — '
            'check assets/ml/sufficiency_model.report.json '
            '("calibrationDecision") and update this expectation deliberately',
      );
      // With no calibrator the two paths must be the same number, not merely
      // similar — otherwise "calibrated" would be silently meaningless.
      const features = {'graph.supportsEdgeCount': 7.0};
      expect(
        loaded.probabilityFor(features),
        equals(loaded.uncalibratedProbabilityFor(features)),
      );
    });

    test('when present it is applied, and the raw score stays reachable', () {
      final loaded = TrainedArtifact.fromJson(withCalibration({
        'blockMaxScore': [0.4, 0.8, 1.0],
        'blockValue': [0.1, 0.5, 0.9],
      }));

      expect(loaded.isCalibrated, isTrue);

      const features = {'graph.supportsEdgeCount': 10.0};
      final raw = loaded.uncalibratedProbabilityFor(features);
      expect(raw, greaterThan(0.8)); // weight 2.0 at the top of the range
      // Step function: the first block whose bound is >= the raw score.
      expect(loaded.probabilityFor(features), equals(0.9));
      expect(loaded.probabilityFor(features), isNot(equals(raw)));
    });

    test('it steps rather than interpolating between block bounds', () {
      // The distinction the Python side hand-rolls PAVA to preserve. A linear
      // interpolation would return something between 0.1 and 0.5 here.
      final c = IsotonicCalibrator.fromTrainedJson({
        'method': 'isotonic',
        'representation': 'pavaBlocks',
        'blockMaxScore': [0.4, 0.8],
        'blockValue': [0.1, 0.5],
      });
      expect(c.calibrate(0.4), equals(0.1));
      expect(c.calibrate(0.6), equals(0.5));
      expect(c.calibrate(0.8), equals(0.5));
    });

    test('it holds flat outside the calibration data support', () {
      final c = IsotonicCalibrator.fromTrainedJson({
        'method': 'isotonic',
        'representation': 'pavaBlocks',
        'blockMaxScore': [0.4, 0.8],
        'blockValue': [0.1, 0.5],
      });
      expect(c.calibrate(-99.0), equals(0.1));
      expect(c.calibrate(99.0), equals(0.5));
    });

    test('a non-monotonic fit is rejected', () {
      expect(
        () => TrainedArtifact.fromJson(withCalibration({
          'blockMaxScore': [0.4, 0.8],
          'blockValue': [0.5, 0.1], // decreasing: not an isotonic fit
        })),
        throwsFormatException,
      );
    });

    test('misaligned blocks are rejected', () {
      expect(
        () => TrainedArtifact.fromJson(withCalibration({
          'blockMaxScore': [0.4, 0.8],
          'blockValue': [0.1],
        })),
        throwsFormatException,
      );
    });

    test('a value outside [0,1] is rejected', () {
      expect(
        () => TrainedArtifact.fromJson(withCalibration({
          'blockMaxScore': [0.4, 0.8],
          'blockValue': [0.1, 1.4],
        })),
        throwsFormatException,
      );
    });

    test('an interpolated representation is refused, not stepped through', () {
      // The failure this guard exists for: a future exporter switching to
      // scikit-learn's knots would produce a subtly different function, and
      // evaluating it as a step function would be wrong everywhere between
      // knots — plausibly, quietly wrong.
      expect(
        () => IsotonicCalibrator.fromTrainedJson({
          'method': 'isotonic',
          'representation': 'linearKnots',
          'blockMaxScore': [0.4],
          'blockValue': [0.1],
        }),
        throwsFormatException,
      );
    });

    test('an unknown calibration method is refused', () {
      expect(
        () => IsotonicCalibrator.fromTrainedJson({
          'method': 'platt',
          'representation': 'pavaBlocks',
          'blockMaxScore': [0.4],
          'blockValue': [0.1],
        }),
        throwsFormatException,
      );
    });
  });

  group('a malformed artifact is rejected, not guessed at', () {
    Map<String, dynamic> valid() => {
          'schemaVersion': SufficiencyModel.supportedSchemaVersion,
          'trainedOnSyntheticData': true,
          'isValidatedOnRealData': false,
          'bias': -0.14,
          'features': [
            {
              'name': 'graph.supportsEdgeCount',
              'weight': 1.34,
              'lo': 0.0,
              'hi': 10.0,
            },
          ],
        };

    test('the control case parses', () {
      expect(() => SufficiencyModel.fromTrainedJson(valid()), returnsNormally);
    });

    test('an unknown schema version', () {
      expect(
        () => SufficiencyModel.fromTrainedJson(valid()..['schemaVersion'] = 99),
        throwsFormatException,
      );
    });

    test('no features', () {
      expect(
        () => SufficiencyModel.fromTrainedJson(valid()..['features'] = []),
        throwsFormatException,
      );
    });

    test('a non-finite weight', () {
      final bad = valid();
      (bad['features'] as List).first['weight'] = 'NaN';
      expect(() => SufficiencyModel.fromTrainedJson(bad), throwsFormatException);
    });

    test('a degenerate range that would delete the feature silently', () {
      final bad = valid();
      (bad['features'] as List).first['hi'] = 0.0;
      expect(() => SufficiencyModel.fromTrainedJson(bad), throwsFormatException);
    });

    test('a duplicated feature', () {
      final bad = valid();
      (bad['features'] as List).add({
        'name': 'graph.supportsEdgeCount',
        'weight': -9.0,
        'lo': 0.0,
        'hi': 10.0,
      });
      expect(() => SufficiencyModel.fromTrainedJson(bad), throwsFormatException);
    });

    test('missing honesty flags', () {
      final bad = valid()..remove('isValidatedOnRealData');
      expect(() => SufficiencyModel.fromTrainedJson(bad), throwsFormatException);
    });

    test('a contradictory provenance claim', () {
      final bad = valid()
        ..['trainedOnSyntheticData'] = true
        ..['isValidatedOnRealData'] = true;
      expect(() => SufficiencyModel.fromTrainedJson(bad), throwsFormatException);
    });
  });
}
