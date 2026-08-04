/// Reads every stored session into memory so the workspace views can aggregate.
///
/// ## Why this loads everything
///
/// [AuditStore.listSessions] returns summaries, which are enough for a list but
/// not for a funnel, a per-skill breakdown, or an evidence count — those need the
/// findings. So this opens each audit.
///
/// That is a deliberate, bounded choice. This is a local-first tool whose entire
/// dataset is the interviews one person has run: a few dozen small JSON
/// documents. Loading them all costs milliseconds and buys arithmetic that is
/// simple and obviously correct. If the dataset ever grew past that, the fix
/// would be to keep aggregate counters at save time — not to sample, and not to
/// compute the dashboard from summaries while labelling it as covering everything.
///
/// ## A session that will not load is reported, never skipped
///
/// A record that fails to parse is carried through as an [UnreadableSession].
/// Dropping it would leave the dashboard's totals quietly short while still
/// presenting them as the whole picture, which is the omission-shaped version of
/// a fabricated number.
library;

import '../persistence/audit_store.dart';
import 'workspace_stats.dart';

/// Everything the workspace views read from, loaded once.
class WorkspaceSnapshot {
  const WorkspaceSnapshot({
    required this.records,
    required this.unreadable,
    required this.stats,
    required this.loadedAt,
    this.storeError,
  });

  final List<SessionRecord> records;
  final List<UnreadableSession> unreadable;
  final WorkspaceStats stats;
  final DateTime loadedAt;

  /// Non-null when the store itself could not be listed. Distinct from an empty
  /// workspace: one is "you have not run a session yet", the other is a fault,
  /// and showing a cheerful zero for the second would be a lie.
  final String? storeError;

  bool get hasFault => storeError != null || unreadable.isNotEmpty;

  SessionRecord? recordFor(String id) {
    for (final record in records) {
      if (record.id == id) return record;
    }
    return null;
  }

  /// Sessions grouped by their operator-typed label, newest group first.
  ///
  /// This is the app's only notion of "a candidate" and the UI says so where it
  /// uses it — see [WorkspaceStats.candidates].
  List<CandidateGroup> get candidates {
    final byLabel = <String, List<SessionRecord>>{};
    for (final record in records) {
      final key = record.label.trim().toLowerCase();
      byLabel.putIfAbsent(key, () => []).add(record);
    }

    final groups = byLabel.values.map((sessions) {
      final sorted = [...sessions]
        ..sort((a, b) => b.audit.sessionEnd.compareTo(a.audit.sessionEnd));
      return CandidateGroup(
        // The most recent spelling wins the display name, so correcting a typo
        // in a later session updates what the list shows.
        label: sorted.first.label,
        sessions: List.unmodifiable(sorted),
      );
    }).toList()
      ..sort((a, b) => b.lastSeen.compareTo(a.lastSeen));

    return List.unmodifiable(groups);
  }
}

/// Every session filed under one label.
class CandidateGroup {
  const CandidateGroup({required this.label, required this.sessions});

  final String label;
  final List<SessionRecord> sessions;

  SessionRecord get latest => sessions.first;
  DateTime get lastSeen => sessions.first.audit.sessionEnd;
  int get claimCount =>
      sessions.fold(0, (sum, s) => sum + s.audit.findings.length);
}

Future<WorkspaceSnapshot> loadWorkspace(AuditStore store) async {
  final now = DateTime.now();

  SessionIndex index;
  try {
    index = await store.listSessions();
  } catch (error) {
    return WorkspaceSnapshot(
      records: const [],
      unreadable: const [],
      stats: WorkspaceStats.empty(),
      loadedAt: now,
      storeError: '$error',
    );
  }

  final records = <SessionRecord>[];
  final unreadable = [...index.unreadable];

  for (final summary in index.sessions) {
    try {
      records.add(SessionRecord(
        summary: summary,
        audit: await store.loadAudit(summary.id),
      ));
    } catch (error) {
      // Listed but not loadable — the index read it enough to name it, and the
      // full record then failed. That is exactly the case worth reporting.
      unreadable.add(UnreadableSession(id: summary.id, problem: '$error'));
    }
  }

  return WorkspaceSnapshot(
    records: List.unmodifiable(records),
    unreadable: List.unmodifiable(unreadable),
    stats: WorkspaceStats.from(records, unreadable: unreadable),
    loadedAt: now,
  );
}
