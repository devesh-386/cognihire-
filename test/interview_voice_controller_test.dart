import 'dart:async';
import 'dart:convert';

import 'package:cognihire/core/claims/claim.dart';
import 'package:cognihire/core/interview/live_turn_client.dart';
import 'package:cognihire/features/interview/interview_voice_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _claim = Claim(
  id: 'c1',
  text: 'Built a food donation platform using Django',
  source: 'resume',
  skill: 'Django',
);

http.Client _alwaysReturning(Map<String, Object?> turnJson) {
  return MockClient.streaming((request, bodyStream) async {
    await bodyStream.drain<void>();
    final controller = StreamController<List<int>>();
    controller.add(utf8.encode('${jsonEncode({
          'message': {'role': 'assistant', 'content': jsonEncode(turnJson)},
          'done': true,
        })}\n'));
    unawaited(controller.close());
    return http.StreamedResponse(controller.stream, 200);
  });
}

http.Client _failingWith(int status) {
  return MockClient.streaming((request, bodyStream) async {
    await bodyStream.drain<void>();
    return http.StreamedResponse(const Stream.empty(), status);
  });
}

void main() {
  test('openWithQuestion puts the opening line where the model can see it',
      () async {
    // This is the exact bug that shipped: a demo set `currentSay` directly
    // instead of recording the opening question in the transcript, so the
    // first real call had no record an interviewer had said anything —
    // it saw only the candidate's answer with nothing to react to, and the
    // model's follow-up came back generic because there was nothing
    // specific in context to ground it against.
    Map<String, Object?>? sentPayload;
    final client = LiveTurnClient(
      client: MockClient.streaming((request, bodyStream) async {
        final bytes = await bodyStream.toBytes();
        final body = jsonDecode(utf8.decode(bytes)) as Map;
        final userMessage =
            (body['messages'] as List).firstWhere((m) => m['role'] == 'user');
        sentPayload = jsonDecode(userMessage['content'] as String) as Map<String, Object?>;
        final controller = StreamController<List<int>>();
        controller.add(utf8.encode('${jsonEncode({
              'message': {
                'role': 'assistant',
                'content': jsonEncode({
                  'say': 'ok',
                  'kind': 'followup',
                  'quote': 'Django',
                  'difficulty_delta': 0,
                  'covered': [],
                  'why': 'x',
                }),
              },
              'done': true,
            })}\n'));
        unawaited(controller.close());
        return http.StreamedResponse(controller.stream, 200);
      }),
    );
    final controller = InterviewVoiceController(
      claims: const [_claim],
      jobRequirements: const [],
      client: client,
    );

    controller.openWithQuestion('Tell me about your Django project.');
    expect(controller.currentSay, 'Tell me about your Django project.');
    expect(controller.transcript, hasLength(1));
    expect(controller.transcript.single.role, 'interviewer');

    await controller.submitCandidateUtterance(
        'I built a food donation platform using Django.');

    final sentTranscript = sentPayload!['transcript'] as List;
    expect(sentTranscript, hasLength(2));
    expect(sentTranscript.first['role'], 'interviewer');
    expect(sentTranscript.first['text'], 'Tell me about your Django project.');
    expect(sentTranscript.last['role'], 'candidate');
  });

  test('a submitted answer moves listening -> thinking -> speaking -> listening',
      () async {
    final controller = InterviewVoiceController(
      claims: const [_claim],
      jobRequirements: const [],
      client: LiveTurnClient(
        client: _alwaysReturning({
          'say': 'How did you handle authentication?',
          'kind': 'followup',
          'quote': 'using Django',
          'difficulty_delta': 0,
          'covered': ['c1'],
          'why': 'Depth probe.',
        }),
      ),
    );

    expect(controller.presence, VoicePresence.listening);

    await controller
        .submitCandidateUtterance('I built it using Django and Postgres.');

    expect(controller.presence, VoicePresence.listening);
    expect(controller.currentSay, 'How did you handle authentication?');
    expect(controller.transcript.length, 2); // candidate turn + interviewer turn
    expect(controller.transcript.first.role, 'candidate');
    expect(controller.transcript.last.role, 'interviewer');
    expect(controller.degradedReason, isNull);
  });

  test('kind close ends the session', () async {
    final controller = InterviewVoiceController(
      claims: const [_claim],
      jobRequirements: const [],
      client: LiveTurnClient(
        client: _alwaysReturning({
          'say': "That's our time, thank you.",
          'kind': 'close',
          'quote': '',
          'difficulty_delta': 0,
          'covered': [],
          'why': 'Time budget exhausted.',
        }),
      ),
    );

    await controller.submitCandidateUtterance('Sure, one more thing...');

    expect(controller.presence, VoicePresence.ended);
  });

  test('a failed turn degrades visibly and returns to listening, not stuck',
      () async {
    final controller = InterviewVoiceController(
      claims: const [_claim],
      jobRequirements: const [],
      client: LiveTurnClient(client: _failingWith(503)),
    );

    await controller.submitCandidateUtterance('I built it using Django.');

    expect(controller.presence, VoicePresence.listening);
    expect(controller.degradedReason, isNotNull);
    // The candidate's own turn is still recorded even though the model call
    // failed — losing what they said would be worse than a missing reply.
    expect(controller.transcript, hasLength(1));
  });

  test('ignores a submission while a turn is already in flight', () async {
    final gate = Completer<void>();
    final controller = InterviewVoiceController(
      claims: const [_claim],
      jobRequirements: const [],
      client: LiveTurnClient(
        client: MockClient.streaming((request, bodyStream) async {
          await bodyStream.drain<void>();
          await gate.future;
          return http.StreamedResponse(
            Stream.value(utf8.encode('${jsonEncode({
                  'message': {
                    'role': 'assistant',
                    'content': jsonEncode({
                      'say': 'ok',
                      'kind': 'followup',
                      'quote': '',
                      'difficulty_delta': 0,
                      'covered': [],
                      'why': 'x',
                    }),
                  },
                  'done': true,
                })}\n')),
            200,
          );
        }),
      ),
    );

    final first = controller.submitCandidateUtterance('First answer here.');
    // Fired while presence is already `thinking` — must be a no-op.
    await controller.submitCandidateUtterance('Second answer, ignored.');
    expect(controller.transcript, hasLength(1));

    gate.complete();
    await first;
    expect(controller.transcript, hasLength(2));
  });
}
