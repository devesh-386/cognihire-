// ignore_for_file: avoid_print — this is a command-line tool whose entire
// output is stdout. A logging framework here would hide the result it exists to
// show.
//
// Smoke-checks the real local model through the real extractor.
//
//   dart run tool/ollama_smoke.dart
//
// The unit tests cover this class against mocked responses, which proves the
// parsing, the grounding gate, and every degradation path — but mocks cannot
// tell you whether the model on *this* machine actually follows the prompt.
// This does. Run it after changing the prompt, switching models, or on a new
// machine before a demo.
import 'package:cognihire/core/claims/ollama_claim_extractor.dart';

const _resume = '''
JANE DOE
jane@example.com | github.com/janedoe

EXPERIENCE
Senior Engineer, Payments — Acme Corp (2023-2025)
- Built a distributed cache in Go for the payments team
- Led the CI migration from Jenkins to GitHub Actions
- Reduced p99 latency by 40% on the checkout service

EDUCATION
B.Tech Computer Science, State University

SKILLS
Go, Python, Kubernetes, PostgreSQL
''';

Future<void> main() async {
  final extractor = OllamaClaimExtractor();

  final warmStart = DateTime.now();
  final ready = await extractor.warmUp();
  final warmMs = DateTime.now().difference(warmStart).inMilliseconds;
  print('warmUp: $ready (${warmMs}ms)');
  if (!ready) {
    print('Ollama is not reachable at ${extractor.baseUrl}. '
        'Extraction will degrade to text rules — which is handled, but you '
        'will not be demoing the model.');
  }

  final start = DateTime.now();
  final result = await extractor.extract(_resume, source: 'Resume');
  final ms = DateTime.now().difference(start).inMilliseconds;

  print('\nextractor: ${result.kind.label} (${ms}ms)');
  if (result.isDegraded) print('DEGRADED: ${result.degradedReason}');

  print('\nclaims (${result.claims.length}):');
  for (final c in result.claims) {
    print('  [${c.id}] ${c.text}${c.skill == null ? '' : '  <${c.skill}>'}');
  }

  if (result.rejectedUngrounded.isEmpty) {
    print('\nungrounded rejections: none');
  } else {
    print('\nungrounded rejections (${result.rejectedUngrounded.length}) — '
        'text the model produced that is NOT in the document:');
    for (final r in result.rejectedUngrounded) {
      print('  - $r');
    }
  }
}
