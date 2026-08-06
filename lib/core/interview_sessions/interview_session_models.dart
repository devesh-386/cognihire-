/// Read-only models over the backend's `interview_sessions` /
/// `interview_events` tables (see `service/session/` and
/// `infra/migrations/0003_interview_sessions.sql`).
///
/// The HR app never writes to these tables — a session's lifecycle is owned
/// entirely by the gateway (`/interview/start` etc.), driven by the
/// candidate portal. This is a reviewer's read-only window onto what
/// happened, scoped to the signed-in organization by RLS, the same way
/// [SupabaseRoleStore] reads `roles`.
library;

class InterviewSessionSummary {
  const InterviewSessionSummary({
    required this.id,
    required this.candidateId,
    required this.status,
    required this.roleTitle,
    required this.completionPercent,
    required this.currentTopic,
    required this.startedAt,
    required this.finishedAt,
  });

  final String id;
  final String candidateId;
  final String status; // in_progress | complete | abandoned
  final String roleTitle;
  final int completionPercent;
  final String? currentTopic;
  final DateTime startedAt;
  final DateTime? finishedAt;

  factory InterviewSessionSummary.fromRow(Map<String, dynamic> row) {
    final coverage = row['coverage_state'] as Map<String, dynamic>? ?? const {};
    return InterviewSessionSummary(
      id: row['id'] as String,
      candidateId: row['candidate_id'] as String,
      status: row['status'] as String? ?? 'in_progress',
      roleTitle: row['role_title'] as String? ?? '',
      completionPercent: (coverage['completion_percent'] as num?)?.toInt() ?? 0,
      currentTopic: row['current_topic'] as String?,
      startedAt: DateTime.parse(row['started_at'] as String),
      finishedAt: row['finished_at'] == null
          ? null
          : DateTime.parse(row['finished_at'] as String),
    );
  }
}

/// One entry from the append-only `interview_events` log — a question, an
/// answer, an analysis verdict, or a coverage update, in the order they
/// happened. This is what makes a session's transcript reconstructable
/// without re-deriving it from `interview_sessions`' current-state columns.
class InterviewEventRecord {
  const InterviewEventRecord({
    required this.sequence,
    required this.eventType,
    required this.payload,
    required this.createdAt,
  });

  final int sequence;
  final String eventType;
  final Map<String, dynamic> payload;
  final DateTime createdAt;

  factory InterviewEventRecord.fromRow(Map<String, dynamic> row) {
    return InterviewEventRecord(
      sequence: (row['sequence'] as num).toInt(),
      eventType: row['event_type'] as String,
      payload: row['payload'] as Map<String, dynamic>? ?? const {},
      createdAt: DateTime.parse(row['created_at'] as String),
    );
  }
}
