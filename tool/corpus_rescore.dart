// ignore_for_file: avoid_print — command-line tool, stdout is the product.
//
// Re-classifies claims already extracted by `tool/corpus_eval.dart`, without
// calling Ollama again.
//
//   dart run tool/corpus_rescore.dart --in tool/corpus/results_24.jsonl
//
// Extraction costs ~25 seconds per resume; classification costs microseconds.
// When a change touches only [QuestionBank.classify], re-running extraction
// would spend twenty minutes reproducing claims we already have, and would
// reproduce them *differently* — the model is not deterministic, so a rerun
// changes the claims and the classification at the same time and you cannot
// tell which change moved the number.
//
// Reading the stored claim text back and re-classifying holds the claims fixed
// and varies only the classifier, which is the comparison actually wanted. The
// `type` recorded in the input file is ignored; it is recomputed here.
import 'dart:convert';
import 'dart:io';

import 'package:cognihire/core/claims/claim.dart';
import 'package:cognihire/core/interview/question_bank.dart';

Future<int> main(List<String> argv) async {
  final path = _argOf(argv, '--in');
  if (path == null) {
    print('usage: dart run tool/corpus_rescore.dart --in <results.jsonl> '
        '[--show-unclassified N]');
    return 64;
  }
  final file = File(path);
  if (!file.existsSync()) {
    print('no such file: $path');
    return 66;
  }
  final show = int.tryParse(_argOf(argv, '--show-unclassified') ?? '') ?? 0;

  var claims = 0;
  var wasNull = 0;
  var nowNull = 0;
  var changed = 0;
  var questions = 0;
  final byType = <String, int>{};
  final nullByCategory = <String, int>{};
  final claimsByCategory = <String, int>{};
  final unclassifiedSamples = <String>[];

  for (final line in file.readAsLinesSync()) {
    if (line.trim().isEmpty) continue;
    final row = jsonDecode(line) as Map<String, dynamic>;
    final category = '${row['category']}';
    for (final raw in (row['claims'] as List)) {
      final c = raw as Map<String, dynamic>;
      final text = '${c['text']}';
      final before = c['type'] as String?;

      final type = QuestionBank.classify(
        Claim(id: 'x', text: text, source: 'Resume'),
      );

      claims++;
      claimsByCategory[category] = (claimsByCategory[category] ?? 0) + 1;
      if (before == null) wasNull++;
      if (type == null) {
        nowNull++;
        nullByCategory[category] = (nullByCategory[category] ?? 0) + 1;
        if (unclassifiedSamples.length < show) unclassifiedSamples.add(text);
      } else {
        byType[type.name] = (byType[type.name] ?? 0) + 1;
        questions +=
            const QuestionBank().ladderFor(
              Claim(id: 'x', text: text, source: 'Resume'),
              type,
            ).length;
      }
      if (before != type?.name) changed++;
    }
  }

  String pct(int n) =>
      claims == 0 ? 'n/a' : '${(100 * n / claims).toStringAsFixed(1)}%';

  print('re-scored $claims claims from $path\n');
  print('unclassified BEFORE   $wasNull  (${pct(wasNull)})');
  print('unclassified AFTER    $nowNull  (${pct(nowNull)})');
  print('classification changed for $changed claims');
  print('questions now generated    $questions');
  print('\nclaim types now:');
  final types = byType.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  for (final e in types) {
    print('  ${e.value.toString().padLeft(5)}  ${e.key}  (${pct(e.value)})');
  }
  if (nullByCategory.isNotEmpty) {
    print('\nstill unclassified, by category (worst first):');
    final worst = nullByCategory.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    for (final e in worst.take(12)) {
      final total = claimsByCategory[e.key] ?? 0;
      final p = total == 0
          ? 'n/a'
          : '${(100 * e.value / total).toStringAsFixed(0)}%';
      print('  ${e.value.toString().padLeft(4)}/${total.toString().padRight(4)}'
          '  ${p.padLeft(5)}  ${e.key}');
    }
  }
  if (unclassifiedSamples.isNotEmpty) {
    print('\nsample of what is still unclassified:');
    for (final s in unclassifiedSamples) {
      print('  - ${s.length > 100 ? '${s.substring(0, 100)}...' : s}');
    }
  }
  return 0;
}

String? _argOf(List<String> argv, String name) {
  final i = argv.indexOf(name);
  return (i == -1 || i + 1 >= argv.length) ? null : argv[i + 1];
}
