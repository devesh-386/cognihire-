// ignore_for_file: avoid_print — this is a command-line tool whose entire
// output is stdout.
//
// Turns a corpus of labelled face-embedding pairs into an FAR/FRR/EER report
// and a calibrated PlattScaler — the missing link between the metrics
// already proven correct in `identity_calibration_test.dart` and an actual
// validated threshold, per the P2 roadmap item in `docs/PRODUCT_OVERVIEW.md`.
//
//   dart run tool/calibrate_threshold.dart --in tool/corpus/identity_pairs.jsonl
//
// ## Input format
//
// One JSON object per line:
//   {"embeddingA": [...512 floats...], "embeddingB": [...512 floats...],
//    "label": "genuine" | "impostor"}
//
// "genuine" = both embeddings are captures of the same enrolled person, at
// different times/poses/sessions. "impostor" = captures of two different
// people. This tool does not — and cannot — generate that corpus; it must
// come from real paired captures (see `docs/ML_REDESIGN.md` §5 for the
// collection protocol). A file of synthetic vectors would produce numbers
// that describe nothing about real faces, which is exactly the kind of
// fabricated confidence this project's threshold docs (`identity_matcher.dart`)
// explicitly refuse to report.
//
// ## What this tool refuses to do
//
// It will not compute or print an EER/FAR/FRR figure from fewer than
// [_minPairsPerClass] examples per class, and it will not run at all if
// either class is completely absent. Both are hard failures (nonzero exit),
// not warnings — a report that silently ran on 3 pairs and printed a number
// indistinguishable from one run on 300 would be the same category of error
// the project's citation-discipline rule exists to catch.
import 'dart:convert';
import 'dart:io';

import 'package:cognihire/core/verification/biometric_metrics.dart';
import 'package:cognihire/core/verification/identity_matcher.dart';
import 'package:cognihire/core/verification/platt_scaler.dart';

/// Below this many pairs per class, FAR/FRR/EER are noise, not a result.
/// 50 is the number this project has already committed to in the roadmap
/// (`docs/PRODUCT_OVERVIEW.md` P2, `MENTOR_BRIEF.md` §8) — chosen there as
/// the smallest sample where a handful of camera-quality outliers can't flip
/// the reported error rate.
const _minPairsPerClass = 50;

/// The threshold currently shipped in [IdentityMatcher] — what this report
/// compares the data-driven EER threshold against.
const _deployedThreshold = 0.50;

Future<void> main(List<String> argv) async {
  exit(await _run(argv));
}

Future<int> _run(List<String> argv) async {
  final args = _Args.parse(argv);
  if (args == null) {
    print('usage: dart run tool/calibrate_threshold.dart --in <pairs.jsonl> '
        '[--out <report.json>]');
    return 64;
  }

  final inputFile = File(args.input);
  if (!inputFile.existsSync()) {
    print('no such file: ${args.input}');
    print('this tool does not generate pair data — see the format and '
        'collection protocol documented at the top of this file and in '
        'docs/ML_REDESIGN.md §5.');
    return 66;
  }

  final genuine = <double>[];
  final impostor = <double>[];
  var skippedUnmeasurable = 0;
  var lineNo = 0;

  for (final line in inputFile.readAsLinesSync()) {
    lineNo++;
    if (line.trim().isEmpty) continue;

    final Map<String, dynamic> row;
    try {
      row = jsonDecode(line) as Map<String, dynamic>;
    } catch (e) {
      print('line $lineNo: not valid JSON, skipping ($e)');
      continue;
    }

    final label = row['label'] as String?;
    if (label != 'genuine' && label != 'impostor') {
      print('line $lineNo: label must be "genuine" or "impostor", got '
          '${jsonEncode(label)} — skipping');
      continue;
    }

    final a = (row['embeddingA'] as List?)?.map((e) => (e as num).toDouble()).toList();
    final b = (row['embeddingB'] as List?)?.map((e) => (e as num).toDouble()).toList();
    final score = IdentityMatcher.cosineSimilarity(a ?? const [], b ?? const []);
    if (score == null) {
      skippedUnmeasurable++;
      continue;
    }

    (label == 'genuine' ? genuine : impostor).add(score);
  }

  print('parsed ${genuine.length} genuine, ${impostor.length} impostor pairs '
      'from $lineNo lines ($skippedUnmeasurable unmeasurable, skipped)\n');

  if (genuine.length < _minPairsPerClass || impostor.length < _minPairsPerClass) {
    print('REFUSING TO REPORT: need at least $_minPairsPerClass pairs per '
        'class to say anything meaningful.');
    print('  genuine:  ${genuine.length} / $_minPairsPerClass');
    print('  impostor: ${impostor.length} / $_minPairsPerClass');
    print('\nThis is not a bug — a threshold "validated" on a handful of '
        'pairs is worse than an honestly unvalidated one, because it invites '
        'citing a number that does not hold up. Collect more pairs.');
    return 1;
  }

  final eer = BiometricMetrics.equalErrorRate(
    genuineScores: genuine,
    impostorScores: impostor,
  );
  final deployedFar = BiometricMetrics.falseAcceptRate(
    impostorScores: impostor,
    threshold: _deployedThreshold,
  );
  final deployedFrr = BiometricMetrics.falseRejectRate(
    genuineScores: genuine,
    threshold: _deployedThreshold,
  );

  final scaler = PlattScaler.fit(
    scores: [...genuine, ...impostor],
    labels: [
      for (var i = 0; i < genuine.length; i++) true,
      for (var i = 0; i < impostor.length; i++) false,
    ],
  );

  print('=' * 62);
  print('IDENTITY THRESHOLD CALIBRATION');
  print('=' * 62);
  print('corpus:            ${genuine.length} genuine, ${impostor.length} '
      'impostor pairs');
  print('');
  print('deployed threshold  $_deployedThreshold (raw cosine)');
  print('  FAR at deployed   ${_pct(deployedFar)}  (impostors wrongly '
      'accepted)');
  print('  FRR at deployed   ${_pct(deployedFrr)}  (genuine users wrongly '
      'rejected)');
  print('');
  print('EER-optimal threshold  ${eer.threshold.toStringAsFixed(4)} (raw '
      'cosine)');
  print('  EER at that point     ${_pct(eer.eer)}');
  print('');
  print('Platt scaler fit on this corpus: isCalibrated=${scaler.isCalibrated}');
  print('  P(genuine | score=deployed threshold) = '
      '${scaler.predict(_deployedThreshold).toStringAsFixed(4)}');
  print('');
  print('This report describes ONLY the corpus at ${args.input}. It does '
      'not become "the" validated FAR/FRR until the collection protocol in '
      'docs/ML_REDESIGN.md §5 has been followed for real candidate pairs — '
      'label this corpus (synthetic/pilot/production) wherever this report '
      'is cited.');

  if (args.output != null) {
    File(args.output!).writeAsStringSync(jsonEncode({
      'corpusPath': args.input,
      'genuineCount': genuine.length,
      'impostorCount': impostor.length,
      'deployedThreshold': _deployedThreshold,
      'deployedFar': deployedFar,
      'deployedFrr': deployedFrr,
      'eerThreshold': eer.threshold,
      'eer': eer.eer,
      'plattCalibrated': scaler.isCalibrated,
    }));
    print('\nreport written: ${args.output}');
  }

  return 0;
}

String _pct(double v) => '${(100 * v).toStringAsFixed(2)}%';

class _Args {
  _Args({required this.input, this.output});
  final String input;
  final String? output;

  static _Args? parse(List<String> argv) {
    String? input, output;
    for (var i = 0; i < argv.length - 1; i += 2) {
      switch (argv[i]) {
        case '--in':
          input = argv[i + 1];
        case '--out':
          output = argv[i + 1];
      }
    }
    if (input == null) return null;
    return _Args(input: input, output: output);
  }
}
