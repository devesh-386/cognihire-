import 'package:cognihire/core/interview/followup.dart';
import 'package:cognihire/core/telemetry/process_telemetry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final start = DateTime(2026, 7, 27, 10, 0, 0);
  const generator = FollowUpGenerator();

  ProcessTelemetry telemetry() => ProcessTelemetry(taskStartedAt: start);

  test('ordinary typing produces no follow-ups', () {
    final t = telemetry();
    for (var i = 1; i <= 40; i++) {
      t.record(i * 3, at: start.add(Duration(seconds: 10 + i)));
    }
    expect(generator.generate(t), isEmpty);
  });

  test('a bulk insert produces a walk-me-through question', () {
    final t = telemetry();
    t.record(10, at: start.add(const Duration(seconds: 20)));
    t.record(300, at: start.add(const Duration(seconds: 25)));

    final followUps = generator.generate(t);
    expect(followUps, hasLength(1));
    expect(followUps.first.trigger, FollowUpTrigger.bulkInsert);
    expect(followUps.first.question.toLowerCase(), contains('walk me through'));
    // The observation must be a measurement, not an allegation.
    expect(followUps.first.observation, contains('290 characters'));
    expect(followUps.first.observation.toLowerCase(),
        isNot(anyOf(contains('cheat'), contains('suspicious'))));
  });

  test('a long pause before a bulk insert changes the question asked', () {
    final t = telemetry();
    t.record(10, at: start.add(const Duration(seconds: 10)));
    t.record(400, at: start.add(const Duration(seconds: 90))); // 80s pause

    final followUps = generator.generate(t);
    expect(followUps.first.trigger, FollowUpTrigger.pauseThenBulk);
    expect(followUps.first.question, contains('pause'));
  });

  test('an instant start is asked about, not penalised', () {
    final t = telemetry();
    t.record(20, at: start.add(const Duration(seconds: 2)));

    final followUps = generator.generate(t);
    final immediate = followUps
        .where((f) => f.trigger == FollowUpTrigger.immediateAnswer)
        .toList();

    expect(immediate, hasLength(1));
    // Phrased as a genuine question with an innocent answer available.
    expect(immediate.first.question, contains('had you seen this problem'));
  });

  test('follow-ups cover every bulk span, largest first', () {
    final t = telemetry();
    t.record(60, at: start.add(const Duration(seconds: 20))); // +60
    t.record(500, at: start.add(const Duration(seconds: 25))); // +440
    t.record(600, at: start.add(const Duration(seconds: 30))); // +100

    final bulk = generator
        .generate(t)
        .where((f) => f.trigger != FollowUpTrigger.immediateAnswer)
        .toList();

    expect(bulk, hasLength(3));
    expect(bulk.first.observation, contains('440'));
  });

  test('no follow-up carries a score or a verdict field', () {
    final t = telemetry();
    t.record(500, at: start.add(const Duration(seconds: 30)));

    for (final f in generator.generate(t)) {
      // The API surface itself is the guarantee: a FollowUp exposes a
      // question, a trigger and an observation. There is nowhere to put a
      // cheating probability even if someone wanted to.
      expect(f.question, isNotEmpty);
      expect(f.observation, isNotEmpty);
    }
  });
}
