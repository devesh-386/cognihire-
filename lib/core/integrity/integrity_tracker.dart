import 'violation_rules.dart';

/// A single logged integrity observation.
///
/// It records that a measurable event happened, when, and how many of that kind
/// had been seen before it. It carries no impact number: an observation is a
/// thing a reviewer should see, not a quantity of blame.
class IntegrityEvent {
  IntegrityEvent({
    required this.rule,
    required this.occurrenceIndex,
    required this.timestamp,
    this.detail = '',
  });

  final ViolationRule rule;

  /// 1-based count of this rule at the time it was logged (first, second, …).
  /// Kept because "the third focus loss" is a genuine, reportable fact — but it
  /// no longer multiplies into a penalty.
  final int occurrenceIndex;

  final DateTime timestamp;
  final String detail;
}

/// Collects integrity observations for a session.
///
/// ## What changed and why
///
/// This class used to expose a 0–100 `score` — the sum of per-rule weights with
/// a compounding +2 penalty for repeats, capped at 100. That was a
/// cheating-probability proxy: hand-set weights, no ground truth, no way to
/// calibrate, and a single number a human would inevitably read as a verdict.
/// It contradicted the project's own principle that the system measures and the
/// human decides, so it was removed outright rather than replaced with a model.
/// There is no ML substitute here on purpose — the right amount of aggregation
/// for these events is none.
///
/// What remains is an honest, ordered log of measured events. Consumers render
/// the events for a reviewer; nothing sums them.
class IntegrityTracker {
  IntegrityTracker();

  final List<IntegrityEvent> _events = [];
  final Map<ViolationRule, int> _repeatCounts = {};

  /// Observations, most recent first.
  List<IntegrityEvent> get events => List.unmodifiable(_events);

  /// How many times [rule] has been observed this session.
  int occurrencesOf(ViolationRule rule) => _repeatCounts[rule] ?? 0;

  /// Log an observation and return the created event.
  IntegrityEvent log(ViolationRule rule, {String detail = '', DateTime? at}) {
    final occurrence = (_repeatCounts[rule] ?? 0) + 1;
    _repeatCounts[rule] = occurrence;

    final event = IntegrityEvent(
      rule: rule,
      occurrenceIndex: occurrence,
      timestamp: at ?? DateTime.now(),
      detail: detail.isEmpty
          ? '${rule.label} (instance #$occurrence)'
          : detail,
    );

    _events.insert(0, event);
    return event;
  }

  void reset() {
    _events.clear();
    _repeatCounts.clear();
  }
}
