import 'dart:convert';

import 'package:cognihire/core/claims/claim_extractor.dart';
import 'package:cognihire/core/claims/ollama_claim_extractor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Tests for local-model claim extraction.
///
/// The interesting tests here are not "does it parse JSON" — they are the two
/// rules that make a language model safe to point at a person's resume: it may
/// **select** text but never **author** it, and when it is unavailable the system
/// degrades visibly instead of guessing or crashing.
const _resume = '''
EXPERIENCE
- Built a distributed cache in Go for the payments team
- Led the CI migration from Jenkins to GitHub Actions
- Reduced p99 latency by 40% on the checkout service
jane@example.com
''';

http.Client _respondingWith(Object body, {int status = 200}) {
  return MockClient((request) async {
    expect(request.url.path, '/api/chat');
    final sent = jsonDecode(request.body) as Map;
    // The document must actually be sent, and nothing may be streamed — a
    // streamed response would not parse as a single envelope.
    expect(sent['stream'], false);
    expect(sent['format'], 'json');
    return http.Response(
      body is String ? body : jsonEncode(body),
      status,
      headers: const {'content-type': 'application/json'},
    );
  });
}

Object _chatEnvelope(Object claimsPayload) => {
      'model': 'qwen2.5:7b',
      'message': {
        'role': 'assistant',
        'content':
            claimsPayload is String ? claimsPayload : jsonEncode(claimsPayload),
      },
      'done': true,
    };

void main() {
  test('extracts verbatim claims and reports the local-model provenance',
      () async {
    final extractor = OllamaClaimExtractor(
      client: _respondingWith(_chatEnvelope({
        'claims': [
          {
            'text': 'Built a distributed cache in Go for the payments team',
            'skill': 'Go',
          },
          {
            'text': 'Led the CI migration from Jenkins to GitHub Actions',
            'skill': 'GitHub Actions',
          },
        ],
      })),
    );

    final result = await extractor.extract(_resume, source: 'Resume');

    expect(result.kind, ExtractorKind.localLlm);
    expect(result.isDegraded, isFalse);
    expect(result.claims, hasLength(2));
    expect(result.claims.first.text,
        'Built a distributed cache in Go for the payments team');
    expect(result.claims.first.skill, 'Go');
    expect(result.claims.first.source, 'Resume');
    expect(result.rejectedUngrounded, isEmpty);
  });

  test('a claim the model invented is discarded and reported', () async {
    final extractor = OllamaClaimExtractor(
      client: _respondingWith(_chatEnvelope({
        'claims': [
          {
            'text': 'Built a distributed cache in Go for the payments team',
            'skill': 'Go',
          },
          // Plausible, well-formed, and nowhere in the resume.
          {'text': 'Managed a team of twelve engineers at Google', 'skill': null},
        ],
      })),
    );

    final result = await extractor.extract(_resume, source: 'Resume');

    expect(result.claims, hasLength(1));
    expect(result.claims.single.text, contains('distributed cache'));
    expect(result.rejectedUngrounded,
        ['Managed a team of twelve engineers at Google']);
  });

  test('a paraphrase is treated as invention, not as a match', () async {
    final extractor = OllamaClaimExtractor(
      client: _respondingWith(_chatEnvelope({
        'claims': [
          // Same meaning, different words. Not the candidate's words.
          {'text': 'Created a distributed caching layer using Go', 'skill': 'Go'},
        ],
      })),
    );

    final result = await extractor.extract(_resume, source: 'Resume');
    expect(result.claims, isEmpty);
    expect(result.rejectedUngrounded, hasLength(1));
  });

  test('re-wrapped whitespace and different casing still count as grounded',
      () async {
    final extractor = OllamaClaimExtractor(
      client: _respondingWith(_chatEnvelope({
        'claims': [
          {
            'text': 'built a distributed   cache\nin Go for the payments team',
            'skill': 'Go',
          },
        ],
      })),
    );

    final result = await extractor.extract(_resume, source: 'Resume');
    expect(result.claims, hasLength(1),
        reason: 'reflowing a line does not change the words in it');
    expect(result.rejectedUngrounded, isEmpty);
  });

  test('an unreachable service degrades to rules and says so', () async {
    final extractor = OllamaClaimExtractor(
      client: MockClient((_) async => throw const SocketExceptionStub()),
    );

    final result = await extractor.extract(_resume, source: 'Resume');

    expect(result.kind, ExtractorKind.heuristicRule);
    expect(result.isDegraded, isTrue);
    expect(result.degradedReason, contains('could not reach'));
    expect(result.claims, isNotEmpty,
        reason: 'degrading must still produce something usable');
  });

  test('an HTTP error degrades to rules with the status in the reason',
      () async {
    final extractor = OllamaClaimExtractor(
      client: _respondingWith('{"error":"model not found"}', status: 404),
    );

    final result = await extractor.extract(_resume, source: 'Resume');
    expect(result.kind, ExtractorKind.heuristicRule);
    expect(result.degradedReason, contains('404'));
  });

  test('malformed model JSON degrades rather than throwing', () async {
    final extractor = OllamaClaimExtractor(
      client: _respondingWith(_chatEnvelope('this is not json at all')),
    );

    final result = await extractor.extract(_resume, source: 'Resume');
    expect(result.kind, ExtractorKind.heuristicRule);
    expect(result.degradedReason, contains('malformed JSON'));
  });

  test('valid JSON without a claims list degrades', () async {
    final extractor = OllamaClaimExtractor(
      client: _respondingWith(_chatEnvelope({'result': 'ok'})),
    );

    final result = await extractor.extract(_resume, source: 'Resume');
    expect(result.kind, ExtractorKind.heuristicRule);
    expect(result.degradedReason, contains('claims list'));
  });

  test('a timeout degrades and names the budget', () async {
    final extractor = OllamaClaimExtractor(
      timeout: const Duration(milliseconds: 30),
      client: MockClient((_) async {
        await Future<void>.delayed(const Duration(seconds: 5));
        return http.Response('{}', 200);
      }),
    );

    final result = await extractor.extract(_resume, source: 'Resume');
    expect(result.kind, ExtractorKind.heuristicRule);
    expect(result.degradedReason, contains('did not answer'));
  });

  test('an empty document never calls the model', () async {
    var called = false;
    final extractor = OllamaClaimExtractor(
      client: MockClient((_) async {
        called = true;
        return http.Response('{}', 200);
      }),
    );

    final result = await extractor.extract('   \n  ', source: 'Resume');
    expect(called, isFalse);
    expect(result.claims, isEmpty);
    expect(result.isDegraded, isFalse);
  });

  test('duplicates are collapsed and maxCandidates is respected', () async {
    final extractor = OllamaClaimExtractor(
      maxCandidates: 2,
      client: _respondingWith(_chatEnvelope({
        'claims': [
          {'text': 'Built a distributed cache in Go for the payments team'},
          {'text': 'Built a distributed cache in Go for the payments team'},
          {'text': 'Led the CI migration from Jenkins to GitHub Actions'},
          {'text': 'Reduced p99 latency by 40% on the checkout service'},
        ],
      })),
    );

    final result = await extractor.extract(_resume, source: 'Resume');
    expect(result.claims, hasLength(2));
    expect(result.claims.map((c) => c.text).toSet(), hasLength(2));
  });

  test('a null-ish skill becomes null rather than the string "null"', () async {
    final extractor = OllamaClaimExtractor(
      client: _respondingWith(_chatEnvelope({
        'claims': [
          {
            'text': 'Reduced p99 latency by 40% on the checkout service',
            'skill': 'null',
          },
        ],
      })),
    );

    final result = await extractor.extract(_resume, source: 'Resume');
    expect(result.claims.single.skill, isNull);
  });

  test('a bullet marker carried over from the resume is stripped, and the '
      'claim still counts as grounded', () async {
    // This is what qwen2.5:7b actually returns against a real resume: the line
    // verbatim, bullet included.
    final extractor = OllamaClaimExtractor(
      client: _respondingWith(_chatEnvelope({
        'claims': [
          {
            'text': '- Built a distributed cache in Go for the payments team',
            'skill': 'Go',
          },
        ],
      })),
    );

    final result = await extractor.extract(_resume, source: 'Resume');
    expect(result.claims.single.text,
        'Built a distributed cache in Go for the payments team');
    expect(result.rejectedUngrounded, isEmpty);
  });

  test('warmUp reports readiness without throwing', () async {
    // Not _respondingWith: warmUp deliberately sends no `format`, since it only
    // needs the weights loaded and does not parse the answer.
    final ready = OllamaClaimExtractor(
      client: MockClient((_) async => http.Response('{"done":true}', 200)),
    );
    expect(await ready.warmUp(), isTrue);

    final down = OllamaClaimExtractor(
      client: MockClient((_) async => throw const SocketExceptionStub()),
    );
    expect(await down.warmUp(), isFalse);
  });

  test('ids are sequential over the claims actually kept', () async {
    final extractor = OllamaClaimExtractor(
      client: _respondingWith(_chatEnvelope({
        'claims': [
          {'text': 'Invented claim that is not in the document'},
          {'text': 'Built a distributed cache in Go for the payments team'},
          {'text': 'Led the CI migration from Jenkins to GitHub Actions'},
        ],
      })),
    );

    final result = await extractor.extract(_resume, source: 'Resume');
    expect(result.claims.map((c) => c.id), ['c1', 'c2'],
        reason: 'a discarded claim must not leave a gap in the ids');
  });
}

/// Stands in for a connection refusal without depending on `dart:io` in a test
/// that otherwise needs none.
class SocketExceptionStub implements Exception {
  const SocketExceptionStub();
  @override
  String toString() => 'Connection refused';
}
