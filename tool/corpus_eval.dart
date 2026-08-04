// ignore_for_file: avoid_print — this is a command-line tool whose entire
// output is stdout. A logging framework here would hide the result it exists to
// show.
//
// Runs the real resume pipeline over a corpus and reports what it does.
//
//   python tool/corpus_prep.py --csv <Resume.csv> --out tool/corpus/sample.jsonl
//   dart run tool/corpus_eval.dart --in tool/corpus/sample.jsonl \
//       --out tool/corpus/results.jsonl
//
// ## Why this drives the production classes directly
//
// `tool/ollama_smoke.dart` proves the extractor works on one hand-written
// resume. Unit tests prove the parsing and the grounding gate against mocks.
// Neither tells you what happens on 2,484 real resumes written by chefs,
// advocates and fitness instructors — which is the only question that matters
// before claiming this pipeline works.
//
// So this imports [OllamaClaimExtractor] and [QuestionBank] and calls them
// exactly as the app does. A reimplementation of the pipeline here would
// measure the reimplementation. Nothing in this file makes an extraction or
// classification decision of its own; it counts what the real code decided.
//
// ## What it is measuring for
//
//   * grounding rejects — text the model authored instead of selected
//   * unclassified claims — [QuestionBank.classify] returns null, which means
//     no question ladder, which means the claim is never probed. On a corpus
//     this far outside software, this is the number expected to hurt.
//   * degradation — how often Ollama fell over and text rules ran instead
//   * claims per resume, and the spread of claim types
import 'dart:convert';
import 'dart:io';

import 'package:cognihire/core/claims/ollama_claim_extractor.dart';
import 'package:cognihire/core/interview/question_bank.dart';

Future<int> main(List<String> argv) async {
  final args = _Args.parse(argv);
  if (args == null) {
    print('usage: dart run tool/corpus_eval.dart --in <sample.jsonl> '
        '[--out <results.jsonl>] [--limit N]');
    return 64;
  }

  final inputFile = File(args.input);
  if (!inputFile.existsSync()) {
    print('no such file: ${args.input}');
    print('run tool/corpus_prep.py first.');
    return 66;
  }

  final rows = inputFile
      .readAsLinesSync()
      .where((l) => l.trim().isNotEmpty)
      .map((l) => jsonDecode(l) as Map<String, dynamic>)
      .toList();
  final selected = args.limit == null ? rows : rows.take(args.limit!).toList();

  final extractor = OllamaClaimExtractor();
  final ready = await extractor.warmUp();
  print('ollama warmUp: $ready  (${extractor.baseUrl}, ${extractor.model})');
  if (!ready) {
    // Loud, because a run in this state measures the fallback text rules, not
    // the model — and a report that quietly conflated the two would be worse
    // than no report.
    print('');
    print('!! Ollama is NOT reachable. Every resume will degrade to text');
    print('!! rules. That is a valid thing to measure, but it is NOT a');
    print('!! measurement of the language-model extraction path.');
  }
  print('evaluating ${selected.length} of ${rows.length} resumes\n');

  final stats = _Stats();
  final out = args.output == null ? null : File(args.output!).openWrite();

  for (var i = 0; i < selected.length; i++) {
    final row = selected[i];
    final id = '${row['id']}';
    final category = '${row['category']}';
    final text = '${row['text']}';

    final started = DateTime.now();
    final result = await extractor.extract(text, source: 'Resume $id');
    final ms = DateTime.now().difference(started).inMilliseconds;

    final claimRecords = <Map<String, dynamic>>[];
    for (final claim in result.claims) {
      final type = QuestionBank.classify(claim);
      final questions = type == null
          ? const <Question>[]
          : const QuestionBank().ladderFor(claim, type);
      stats.recordClaim(category, type, questions.length);
      claimRecords.add({
        'text': claim.text,
        'skill': claim.skill,
        'type': type?.name,
        'questions': questions.map((q) => q.text).toList(),
      });
    }

    stats.recordResume(
      category: category,
      chars: text.length,
      claims: result.claims.length,
      rejected: result.rejectedUngrounded.length,
      degraded: result.isDegraded,
      ms: ms,
    );

    out?.writeln(jsonEncode({
      'id': id,
      'category': category,
      'chars': text.length,
      'ms': ms,
      'extractor': result.kind.name,
      'degradedReason': result.degradedReason,
      'claims': claimRecords,
      'rejectedUngrounded': result.rejectedUngrounded,
    }));

    final flag = result.isDegraded ? ' DEGRADED' : '';
    print('[${i + 1}/${selected.length}] $category  $id  '
        '${result.claims.length} claims, '
        '${result.rejectedUngrounded.length} rejected, ${ms}ms$flag');
  }

  await out?.flush();
  await out?.close();

  stats.report();
  if (args.output != null) print('\nper-resume detail: ${args.output}');
  return 0;
}

/// Counters only. Every judgement in this file was made by the production
/// classes; this just tallies them.
class _Stats {
  int resumes = 0;
  int degraded = 0;
  int claims = 0;
  int rejected = 0;
  int unclassified = 0;
  int questions = 0;
  int totalMs = 0;
  int zeroClaimResumes = 0;

  final Map<String, int> byType = {};
  final Map<String, int> unclassifiedByCategory = {};
  final Map<String, int> claimsByCategory = {};

  void recordResume({
    required String category,
    required int chars,
    required int claims,
    required int rejected,
    required bool degraded,
    required int ms,
  }) {
    resumes++;
    this.claims += claims;
    this.rejected += rejected;
    totalMs += ms;
    if (degraded) this.degraded++;
    if (claims == 0) zeroClaimResumes++;
    claimsByCategory[category] = (claimsByCategory[category] ?? 0) + claims;
  }

  void recordClaim(String category, ClaimType? type, int questionCount) {
    questions += questionCount;
    if (type == null) {
      unclassified++;
      unclassifiedByCategory[category] =
          (unclassifiedByCategory[category] ?? 0) + 1;
    } else {
      byType[type.name] = (byType[type.name] ?? 0) + 1;
    }
  }

  String _pct(int n, int d) =>
      d == 0 ? 'n/a' : '${(100 * n / d).toStringAsFixed(1)}%';

  void report() {
    print('\n${'=' * 62}');
    print('CORPUS EVALUATION');
    print('=' * 62);
    print('resumes                 $resumes');
    print('  degraded to rules     $degraded  (${_pct(degraded, resumes)})');
    print('  yielded zero claims   $zeroClaimResumes  '
        '(${_pct(zeroClaimResumes, resumes)})');
    print('  mean latency          ${resumes == 0 ? 0 : totalMs ~/ resumes}ms');
    print('');
    print('claims kept             $claims');
    print('claims rejected         $rejected  ungrounded  '
        '(${_pct(rejected, claims + rejected)} of everything proposed)');
    print('');
    print('UNCLASSIFIED            $unclassified  (${_pct(unclassified, claims)}'
        ' of kept claims)');
    print('  -> these get NO question ladder and are never probed');
    print('questions generated     $questions');
    print('');
    print('claim types:');
    final types = byType.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    for (final e in types) {
      print('  ${e.value.toString().padLeft(5)}  ${e.key}  '
          '(${_pct(e.value, claims)})');
    }
    if (unclassifiedByCategory.isNotEmpty) {
      print('\nunclassified by category (worst first):');
      final worst = unclassifiedByCategory.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      for (final e in worst.take(10)) {
        final total = claimsByCategory[e.key] ?? 0;
        print('  ${e.value.toString().padLeft(4)}/${total.toString().padRight(4)}'
            '  ${_pct(e.value, total).padLeft(6)}  ${e.key}');
      }
    }
  }
}

class _Args {
  _Args({required this.input, this.output, this.limit});
  final String input;
  final String? output;
  final int? limit;

  static _Args? parse(List<String> argv) {
    String? input, output, limit;
    for (var i = 0; i < argv.length - 1; i += 2) {
      switch (argv[i]) {
        case '--in':
          input = argv[i + 1];
        case '--out':
          output = argv[i + 1];
        case '--limit':
          limit = argv[i + 1];
      }
    }
    if (input == null) return null;
    return _Args(
      input: input,
      output: output,
      limit: limit == null ? null : int.tryParse(limit),
    );
  }
}
