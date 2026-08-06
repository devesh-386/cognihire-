/// Read-only Supabase access to backend-driven interview sessions.
///
/// Same shape as [SupabaseRoleStore]: RLS on `interview_sessions` /
/// `interview_events` already restricts every read to the signed-in
/// reviewer's organization, so this store never needs to know or pass an
/// organization id — it just asks and trusts the database to have scoped
/// the answer.
library;

import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

import 'interview_session_models.dart';

class InterviewSessionListResult {
  const InterviewSessionListResult({required this.sessions, this.problem});

  final List<InterviewSessionSummary> sessions;
  final String? problem;
}

class SupabaseInterviewSessionStore {
  SupabaseInterviewSessionStore(this._client);

  final supabase.SupabaseClient _client;

  Future<InterviewSessionListResult> listSessions() async {
    try {
      final rows = await _client
          .from('interview_sessions')
          .select()
          .order('started_at', ascending: false);
      final sessions = (rows as List)
          .map((row) =>
              InterviewSessionSummary.fromRow(row as Map<String, dynamic>))
          .toList();
      return InterviewSessionListResult(sessions: sessions);
    } catch (error) {
      return InterviewSessionListResult(
        sessions: const [],
        problem: error.toString(),
      );
    }
  }

  /// Ticket 21: the interview code that redeemed into this session, if any
  /// — used to look up its Email Status. Returns null on any failure
  /// (including "no code found") rather than throwing; the detail screen
  /// simply omits the Email Status section in that case.
  Future<String?> findCodeIdForSession(String sessionId) async {
    try {
      final row = await _client
          .from('interview_codes')
          .select('id')
          .eq('session_id', sessionId)
          .maybeSingle();
      return row?['id'] as String?;
    } catch (_) {
      return null;
    }
  }

  Future<List<InterviewEventRecord>> listEvents(String sessionId) async {
    final rows = await _client
        .from('interview_events')
        .select()
        .eq('session_id', sessionId)
        .order('sequence', ascending: true);
    return (rows as List)
        .map((row) => InterviewEventRecord.fromRow(row as Map<String, dynamic>))
        .toList();
  }
}
