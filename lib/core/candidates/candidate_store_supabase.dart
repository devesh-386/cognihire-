/// Supabase-backed [CandidateStore]. RLS-scoped by organization (same
/// `auth_organization_id()` policy as roles/intakes) — this reads only the
/// signed-in recruiter's own organization's candidates, same guarantee
/// [SupabaseRoleStore] gives for roles.
library;

import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

import 'candidate.dart';
import 'candidate_store.dart';

class SupabaseCandidateStore implements CandidateStore {
  SupabaseCandidateStore(this._client);

  final supabase.SupabaseClient _client;

  @override
  Future<List<Candidate>> listCandidates() async {
    // Foreign-key embedding (roles(title), intakes(name)) rather than N+1
    // lookups — candidates.role_id -> roles.id and candidates.intake_id ->
    // intakes.id are real FKs, so PostgREST can join them in one request.
    final rows = await _client
        .from('candidates')
        .select('*, roles(title), intakes(name)')
        .order('created_at', ascending: false);

    final candidateIds = rows.map((r) => r['id'] as String).toList();
    final statusByCandidate = <String, String>{};
    if (candidateIds.isNotEmpty) {
      final profiles = await _client
          .from('candidate_ai_profile')
          .select('candidate_id, processing_status')
          .inFilter('candidate_id', candidateIds);
      for (final r in profiles) {
        statusByCandidate[r['candidate_id'] as String] = r['processing_status'] as String;
      }
    }

    return rows.map((r) {
      final role = r['roles'] as Map<String, dynamic>?;
      final intake = r['intakes'] as Map<String, dynamic>?;
      return Candidate(
        id: r['id'] as String,
        name: r['name'] as String,
        email: r['email'] as String,
        createdAt: DateTime.parse(r['created_at'] as String),
        roleId: r['role_id'] as String?,
        roleTitle: role?['title'] as String?,
        intakeId: r['intake_id'] as String?,
        intakeName: intake?['name'] as String?,
        processingStatus: statusByCandidate[r['id'] as String],
      );
    }).toList();
  }
}
