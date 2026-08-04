import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cognihire/core/claims/claim.dart';
import 'package:cognihire/core/interview/live_turn_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Tests for the live turn client.
///
/// The interesting tests are not "does it parse JSON" — they are the two
/// things this class exists to guarantee that the prompt alone cannot: `say`
/// streams out character by character as it arrives (the entire reason the
/// schema puts it first, see prompts/README.md), and a quote the model invents
/// rather than copies from the transcript never reaches the caller unflagged.
const _claim = Claim(
  id: 'c1',
  text: 'Built a food donation platform using Django',
  source: 'resume',
  skill: 'Django',
);

final _state = InterviewTurnState(
  level: 3,
  askedIds: const ['q1'],
  coveredIds: const [],
  lastAnswerWords: 24,
  lastAnswerScore: 1,
  turnsSinceAck: 3,
  secondsRemaining: 1500,
);

final _transcript = [
  const TranscriptTurn(
      role: 'interviewer', text: 'Tell me about your Django project.'),
  const TranscriptTurn(
      role: 'candidate',
      text:
          'I built a food donation platform using Django and it connected restaurants with shelters.'),
];

/// Streams [lines] back one Ollama-style NDJSON chunk at a time, each on its
/// own event, exactly as `/api/chat` with `stream: true` behaves.
http.Client _streaming(List<Map<String, Object?>> chunks) {
  return MockClient.streaming((request, bodyStream) async {
    expect(request.url.path, '/api/chat');
    final sentBytes = await bodyStream.toBytes();
    final sent = jsonDecode(utf8.decode(sentBytes)) as Map;
    expect(sent['stream'], true);
    expect(sent['format'], 'json');

    final controller = StreamController<List<int>>();
    () async {
      for (final chunk in chunks) {
        controller.add(utf8.encode('${jsonEncode(chunk)}\n'));
        await Future<void>.delayed(Duration.zero);
      }
      await controller.close();
    }();
    return http.StreamedResponse(controller.stream, 200);
  });
}

List<Map<String, Object?>> _streamOf(String fullJson) {
  // Split into a handful of pieces to exercise the partial-parser rather than
  // handing it one already-complete object.
  final mid = fullJson.length ~/ 2;
  return [
    {
      'message': {'role': 'assistant', 'content': fullJson.substring(0, mid)},
      'done': false
    },
    {
      'message': {'role': 'assistant', 'content': fullJson.substring(mid)},
      'done': true
    },
  ];
}

void main() {
  test('emits growing partial say values before the turn completes', () async {
    final turnJson = jsonEncode({
      'say': 'You mentioned Django. How did you handle authentication?',
      'kind': 'followup',
      'quote': 'using Django',
      'difficulty_delta': 0,
      'covered': ['c1'],
      'why': 'Depth probe on the named framework.',
    });

    final client = LiveTurnClient(client: _streaming(_streamOf(turnJson)));
    final partials = <String>[];

    final turn = await client.nextTurn(
      claims: const [_claim],
      jobRequirements: const [],
      transcriptWindow: _transcript,
      state: _state,
      onPartialSay: partials.add,
    );

    expect(turn.say,
        'You mentioned Django. How did you handle authentication?');
    expect(turn.kind, TurnKind.followup);
    expect(turn.wasGrounded, isTrue);
    // The partial callback must have fired with the value growing, and the
    // final partial value must equal the completed say — proving the naive
    // streaming parser and the final jsonDecode agree.
    expect(partials, isNotEmpty);
    expect(partials.last, turn.say);
    expect(partials.first.length, lessThanOrEqualTo(partials.last.length));
  });

  test('discards a quote the model invented instead of copying', () async {
    // "we used Kafka for events" never appears in _transcript — the candidate
    // only ever said "Django". A model that writes this quote is fabricating
    // an attribution, which is the one thing this class must never forward.
    final turnJson = jsonEncode({
      'say': 'You mentioned Kafka — how did you partition the topics?',
      'kind': 'followup',
      'quote': 'we used Kafka for events',
      'difficulty_delta': 0,
      'covered': ['c1'],
      'why': 'Depth probe.',
    });

    final client = LiveTurnClient(client: _streaming(_streamOf(turnJson)));
    final turn = await client.nextTurn(
      claims: const [_claim],
      jobRequirements: const [],
      transcriptWindow: _transcript,
      state: _state,
    );

    expect(turn.wasGrounded, isFalse);
    expect(turn.kind, TurnKind.newtopic);
    expect(turn.quote, isEmpty);
    expect(turn.covered, isEmpty);
    // The spoken words are left untouched — only the machine-readable fields
    // are corrected — because rewriting `say` after the fact is how a
    // candidate ends up hearing something that doesn't match the transcript.
    expect(turn.say, contains('Kafka'));
  });

  test('degrades on a malformed final payload instead of throwing raw',
      () async {
    final client =
        LiveTurnClient(client: _streaming(_streamOf('{not valid json')));

    expect(
      () => client.nextTurn(
        claims: const [_claim],
        jobRequirements: const [],
        transcriptWindow: _transcript,
        state: _state,
      ),
      throwsA(isA<TurnDegraded>()),
    );
  });

  test('degrades on HTTP failure rather than throwing an unlabelled error',
      () async {
    final client = LiveTurnClient(
      client: MockClient.streaming((request, bodyStream) async {
        await bodyStream.drain<void>();
        return http.StreamedResponse(const Stream.empty(), 503);
      }),
    );

    expect(
      () => client.nextTurn(
        claims: const [_claim],
        jobRequirements: const [],
        transcriptWindow: _transcript,
        state: _state,
      ),
      throwsA(isA<TurnDegraded>()),
    );
  });

  test('the embedded system prompt has not drifted from prompts/interview_agent.v2.txt',
      () {
    // This is the exact bug that shipped: LiveTurnClient's default prompt was
    // a placeholder that only *described* loading the file, so the model got
    // no output contract at all and returned JSON with no `say` field —
    // surfacing live as "Couldn't reach the local model... the local model
    // returned an empty say field", which reads like a connectivity problem
    // and isn't one. Run from the project root (`flutter test` does).
    final onDisk =
        File('prompts/interview_agent.v2.txt').readAsStringSync().trim();
    expect(
      LiveTurnClient.defaultSystemPrompt.trim(),
      onDisk,
      reason: 'lib/core/interview/live_turn_client.dart\'s embedded prompt '
          'must be kept byte-for-byte in sync with the .txt file the eval '
          'gate scores — see defaultSystemPrompt\'s doc comment.',
    );
  });

  test('warmUp reports true on a healthy response and false without throwing',
      () async {
    final healthy = LiveTurnClient(
      client: MockClient((request) async {
        expect(request.url.path, '/api/chat');
        final sent = jsonDecode(request.body) as Map;
        expect(sent['stream'], false);
        return http.Response(
          jsonEncode({'message': {'role': 'assistant', 'content': 'ok'}}),
          200,
        );
      }),
    );
    expect(await healthy.warmUp(), isTrue);

    // Connection refused is the expected shape of "Ollama isn't running" —
    // this is the case a caller checks before deciding to show "waking up"
    // vs "couldn't reach the local model" (see live_interview_demo.dart).
    final unreachable = LiveTurnClient(
      client: MockClient((request) async => throw Exception('refused')),
    );
    expect(await unreachable.warmUp(), isFalse);
  });
}
