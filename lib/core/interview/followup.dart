import '../telemetry/edit_event.dart';
import '../telemetry/process_telemetry.dart';

/// A question the interview should ask *now*, triggered by something observed
/// in how the answer was produced.
class FollowUp {
  const FollowUp({
    required this.question,
    required this.trigger,
    required this.observation,
  });

  /// What to ask the candidate.
  final String question;

  /// Why it was asked. Shown to the candidate on request and recorded in the
  /// audit — a candidate is entitled to know what prompted a question about
  /// their own work.
  final FollowUpTrigger trigger;

  /// The neutral, factual observation behind it. Phrased as a measurement,
  /// never as an allegation.
  final String observation;
}

enum FollowUpTrigger {
  /// A span of the answer appeared in one step.
  bulkInsert,

  /// The candidate began producing a complete answer with almost no lead time.
  immediateAnswer,

  /// A long silence immediately preceded a large amount of content.
  pauseThenBulk,
}

/// Turns process observations into live follow-up questions.
///
/// ## The mechanism, and why it is fair
///
/// This is the one anti-substitution measure a scripted assistant cannot
/// survive, and it works precisely *because* it is not an accusation. If a
/// block of code appears at once, the interview asks the candidate to explain
/// that block. Someone who wrote it explains it easily. Someone reading it off
/// a second screen has to comprehend it live, under time pressure, in their own
/// words — which is a materially harder task than producing it was.
///
/// So a bulk insert is never scored, flagged, or reported as misconduct. It
/// selects a question. The candidate's *answer* is the evidence, and the
/// candidate always gets the chance to give it. That is the difference between
/// gathering evidence and presuming guilt, and it is also why this survives
/// the obvious objection: pasting is legitimate, and a candidate who pastes
/// their own prior work will simply answer the question well.
///
/// Deliberately not built: any inference of intent, any "likelihood of
/// assistance" score, any silent flag the candidate never sees.
class FollowUpGenerator {
  const FollowUpGenerator({
    this.immediateAnswerWindow = const Duration(seconds: 5),
    this.pauseBeforeBulk = const Duration(seconds: 30),
  });

  /// A complete answer beginning inside this window from task start is worth
  /// asking about — not because it is suspicious, but because a candidate who
  /// genuinely knew it instantly can say so in one sentence.
  final Duration immediateAnswerWindow;

  /// A pause at least this long immediately before a bulk insert.
  final Duration pauseBeforeBulk;

  /// Build the follow-ups warranted by the current session state.
  ///
  /// Ordered by how much of the answer the question covers, largest first.
  List<FollowUp> generate(ProcessTelemetry telemetry) {
    final signals = telemetry.signals();
    final events = telemetry.events;
    final followUps = <FollowUp>[];

    // 1. Spans that arrived at once — ask the candidate to walk through them.
    for (final span in telemetry.spansWorthProbing()) {
      final precededByPause = _pauseBefore(events, span);

      if (precededByPause != null && precededByPause >= pauseBeforeBulk) {
        followUps.add(FollowUp(
          trigger: FollowUpTrigger.pauseThenBulk,
          observation:
              '${span.delta} characters were added at once after a pause of '
              '${precededByPause.inSeconds}s.',
          question:
              'Talk me through the part you just added — what were you working '
              'out during the pause before it?',
        ));
      } else {
        followUps.add(FollowUp(
          trigger: FollowUpTrigger.bulkInsert,
          observation: '${span.delta} characters were added in one step.',
          question:
              'Walk me through the section you just added. Why did you '
              'structure it that way, and what would break if you changed it?',
        ));
      }
    }

    // 2. An answer that began essentially instantly.
    final ttfk = signals.timeToFirstKeystroke;
    if (ttfk != null &&
        ttfk <= immediateAnswerWindow &&
        signals.finalLength > 0) {
      followUps.add(FollowUp(
        trigger: FollowUpTrigger.immediateAnswer,
        observation:
            'Answering began ${ttfk.inMilliseconds}ms after the task appeared.',
        question:
            'You started straight away — had you seen this problem before? '
            'If so, tell me where, and what you would do differently now.',
      ));
    }

    return List.unmodifiable(followUps);
  }

  /// Gap between [span] and the edit preceding it, or null if it was first.
  Duration? _pauseBefore(List<EditEvent> events, EditEvent span) {
    final index = events.indexOf(span);
    if (index <= 0) return null;
    return span.at.difference(events[index - 1].at);
  }
}
