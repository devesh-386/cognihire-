import 'edit_event.dart';

/// Observations about *how* an answer was produced, as distinct from what the
/// answer says.
///
/// ## Why this exists, stated precisely
///
/// The pitch claim this supports has to be narrow, because the wide version is
/// false. Existing assessment platforms DO capture process telemetry:
/// HackerRank ships keystroke playback and a "Coding Patterns" flag derived
/// from keystroke timing; CodeSignal has full session playback and a suspicion
/// score. Anyone can verify that from a product page.
///
/// What none of them do is feed process signal back into a *live* interview
/// that changes its next question because of what the process showed. They
/// capture it for the coding task in isolation, use it as a retrospective fraud
/// flag, and surface it to a human reviewer after submission.
///
/// So this class produces [ProcessSignals] intended to be consumed *during* the
/// session by the follow-up question generator — not a cheating score.
///
/// ## What this deliberately does not do
///
/// It does not output a probability of cheating, a composite integrity number,
/// or any judgement of intent. Every field below is a measurement with a
/// defined unit. The reference implementation this project learns from derived
/// "words per minute" from a filler-word count with no timing data at all, and
/// logged "phone detected" from ambient brightness. The lesson taken from that
/// is not "measure more carefully" — it is that a measurement and an inference
/// must never be returned by the same function under the same name.
///
/// Interpretation belongs to the adversarial follow-up: if a large block of
/// code appears at once, the response is to *ask about it*, which a candidate
/// who wrote it can answer and a scripted assistant cannot. That is evidence
/// gathering, not accusation.
class ProcessTelemetry {
  ProcessTelemetry({
    required this.taskStartedAt,
    this.bulkInsertThreshold = 40,
    this.bulkDeleteThreshold = 40,
    this.idleGapThreshold = const Duration(seconds: 20),
  });

  /// When the candidate was first shown the task. Time-to-first-keystroke is
  /// measured from here.
  final DateTime taskStartedAt;

  /// Character count above which a single insertion is classed [EditKind.bulkInsert].
  final int bulkInsertThreshold;

  /// Character count above which a single deletion is classed [EditKind.bulkDelete].
  final int bulkDeleteThreshold;

  /// Gap above which the candidate is considered to have paused.
  final Duration idleGapThreshold;

  final List<EditEvent> _events = [];
  int _lastLength = 0;

  List<EditEvent> get events => List.unmodifiable(_events);

  /// Record the buffer's new length at [at].
  ///
  /// Callers pass raw buffer state; classification happens here so the UI layer
  /// holds no interpretation logic.
  EditEvent record(int newLength, {DateTime? at}) {
    final now = at ?? DateTime.now();
    final before = _lastLength;
    final delta = newLength - before;

    final kind = switch (delta) {
      _ when delta >= bulkInsertThreshold => EditKind.bulkInsert,
      _ when delta <= -bulkDeleteThreshold => EditKind.bulkDelete,
      _ => EditKind.typing,
    };

    final event = EditEvent(
      at: now,
      lengthBefore: before,
      lengthAfter: newLength,
      kind: kind,
    );

    _events.add(event);
    _lastLength = newLength;
    return event;
  }

  void reset() {
    _events.clear();
    _lastLength = 0;
  }

  ProcessSignals signals({DateTime? now}) {
    if (_events.isEmpty) {
      return ProcessSignals(
        timeToFirstKeystroke: null,
        totalInserted: 0,
        totalDeleted: 0,
        revisionRatio: null,
        bulkInsertCount: 0,
        largestBulkInsert: 0,
        bulkDeleteCount: 0,
        longestPause: null,
        pauseCount: 0,
        finalLength: 0,
        editCount: 0,
      );
    }

    final first = _events.first;
    var inserted = 0;
    var deleted = 0;
    var bulkInserts = 0;
    var largestBulk = 0;
    var bulkDeletes = 0;

    for (final e in _events) {
      if (e.isInsertion) {
        inserted += e.delta;
      } else if (e.isDeletion) {
        deleted += -e.delta;
      }
      if (e.kind == EditKind.bulkInsert) {
        bulkInserts++;
        if (e.delta > largestBulk) largestBulk = e.delta;
      }
      if (e.kind == EditKind.bulkDelete) bulkDeletes++;
    }

    Duration? longestPause;
    var pauseCount = 0;
    for (var i = 1; i < _events.length; i++) {
      final gap = _events[i].at.difference(_events[i - 1].at);
      if (gap >= idleGapThreshold) {
        pauseCount++;
        if (longestPause == null || gap > longestPause) longestPause = gap;
      }
    }

    return ProcessSignals(
      timeToFirstKeystroke: first.at.difference(taskStartedAt),
      totalInserted: inserted,
      totalDeleted: deleted,
      // Undefined rather than zero when nothing was typed: a ratio with an
      // empty denominator is not "no revision", it is "not measurable".
      revisionRatio: inserted == 0 ? null : deleted / inserted,
      bulkInsertCount: bulkInserts,
      largestBulkInsert: largestBulk,
      bulkDeleteCount: bulkDeletes,
      longestPause: longestPause,
      pauseCount: pauseCount,
      finalLength: _lastLength,
      editCount: _events.length,
    );
  }

  /// Spans of the answer that a live follow-up should ask about.
  ///
  /// Returns the bulk insertions, largest first. These are *prompts for a
  /// question*, never findings. The interview asks "walk me through this part"
  /// — a candidate who wrote it answers easily; that is the whole mechanism.
  List<EditEvent> spansWorthProbing() {
    final bulk = _events.where((e) => e.kind == EditKind.bulkInsert).toList()
      ..sort((a, b) => b.delta.compareTo(a.delta));
    return List.unmodifiable(bulk);
  }
}

/// Measured process signals. Every field is an observation with a unit.
/// Null means "not measurable", never zero-as-a-default.
class ProcessSignals {
  const ProcessSignals({
    required this.timeToFirstKeystroke,
    required this.totalInserted,
    required this.totalDeleted,
    required this.revisionRatio,
    required this.bulkInsertCount,
    required this.largestBulkInsert,
    required this.bulkDeleteCount,
    required this.longestPause,
    required this.pauseCount,
    required this.finalLength,
    required this.editCount,
  });

  /// Time from task start to the first edit. Null if nothing was typed.
  final Duration? timeToFirstKeystroke;

  final int totalInserted;
  final int totalDeleted;

  /// Deleted / inserted. Null when nothing was inserted.
  /// A high ratio means heavy revision — which is a sign of thinking, not of
  /// wrongdoing. It is reported because it is interesting, not because it is
  /// damning.
  final double? revisionRatio;

  final int bulkInsertCount;
  final int largestBulkInsert;
  final int bulkDeleteCount;

  final Duration? longestPause;
  final int pauseCount;

  final int finalLength;
  final int editCount;

  /// True when at least one span arrived too fast to have been typed here.
  /// Grounds for a follow-up question. Not grounds for a conclusion.
  bool get hasSpansWorthProbing => bulkInsertCount > 0;
}
