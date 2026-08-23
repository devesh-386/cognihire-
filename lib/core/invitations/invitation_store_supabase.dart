/// Supabase-backed [InvitationStore] (Ticket 10).
///
/// ## Why this can't be a plain table CRUD wrapper like [SupabaseRoleStore]
///
/// [Invitation] carries `candidateName`/`candidateEmail` directly, but the
/// schema normalises that into a separate `candidates` table (Ticket 8's
/// `cognihire_minimal_schema`) so a future ticket can attach a résumé/intake
/// record to the same candidate. This store hides that join behind the
/// existing [InvitationStore] interface — nothing above it needs to know.
///
/// The bigger reason is RLS: a candidate redeeming a code has no Supabase
/// Auth session at all (deliberately — see `sign_in_screen.dart`), so the
/// organization-scoped RLS policies can never pass for them. [findRedeemable]
/// and the redemption half of [saveInvitation] instead go through two
/// `SECURITY DEFINER` RPCs (`get_redeemable_invitation`, `accept_invitation`)
/// that are the entire anon-facing surface — see the `candidate_invitation_rpcs`
/// migration for exactly what they permit.
library;

import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

import 'invitation.dart';
import 'invitation_store.dart';

class SupabaseInvitationStore implements InvitationStore {
  SupabaseInvitationStore(this._client);

  final supabase.SupabaseClient _client;

  // From appMetadata, not userMetadata — see supabase_auth_store.dart's
  // principalFromUser for why (SEC-001: userMetadata is writable by the
  // signed-in account itself). This was previously read from userMetadata;
  // RLS's `organization_id = auth_organization_id()` WITH CHECK already
  // reads the real app_metadata server-side, so a stale/wrong userMetadata
  // value here only ever produced a rejected write, never an actual
  // cross-org write — but it's the same bug class as SEC-001 and left one
  // path silently un-fixed.
  String? get _organizationId =>
      _client.auth.currentUser?.appMetadata['organization_id'] as String?;

  @override
  Future<InvitationIndex> listInvitations() async {
    try {
      final rows = await _client
          .from('invitations')
          .select('*, candidates(name, email)')
          .order('created_at', ascending: false);
      final invitations = (rows as List)
          .map((row) => _fromJoinedRow(row as Map<String, dynamic>))
          .toList();
      return InvitationIndex(invitations: invitations, problem: null);
    } catch (error) {
      return InvitationIndex(invitations: const [], problem: error.toString());
    }
  }

  @override
  Future<void> saveInvitation(Invitation invitation) async {
    final organizationId = _organizationId;
    if (organizationId == null) {
      // No org on this session: this is the anon candidate-redemption path.
      // The only legal write an unauthenticated caller can make is accepting
      // their own code, which accept_invitation enforces server-side
      // (single-use, code-scoped) regardless of what's in [invitation].
      await _client.rpc('accept_invitation', params: {'p_code': invitation.code});
      return;
    }

    // HR path: create or update. The candidate row is 1:1 with the
    // invitation (keyed off the invitation id) — the domain model has no
    // separate candidate identity yet, matching Invitation's own "deliberately
    // minimal" doc comment.
    final candidateId = 'cand-${invitation.id}';
    await _client.from('candidates').upsert({
      'id': candidateId,
      'organization_id': organizationId,
      'name': invitation.candidateName,
      'email': invitation.candidateEmail,
    });
    await _client.from('invitations').upsert({
      'id': invitation.id,
      'organization_id': organizationId,
      'candidate_id': candidateId,
      'role_id': invitation.roleId,
      'code': invitation.code,
      'status': invitation.status.wireValue,
      'created_at': invitation.createdAt.toIso8601String(),
    });
  }

  @override
  Future<Invitation?> findRedeemable(String code) async {
    final needle = code.trim();
    if (needle.isEmpty) return null;
    final rows = await _client
        .rpc('get_redeemable_invitation', params: {'p_code': needle}) as List;
    if (rows.isEmpty) return null;
    return _fromRpcRow(rows.first as Map<String, dynamic>);
  }

  Invitation _fromJoinedRow(Map<String, dynamic> row) {
    final candidate = row['candidates'] as Map<String, dynamic>?;
    return Invitation(
      id: row['id'] as String,
      candidateName: candidate?['name'] as String? ?? '',
      candidateEmail: candidate?['email'] as String? ?? '',
      roleId: row['role_id'] as String,
      code: row['code'] as String,
      createdAt: DateTime.parse(row['created_at'] as String),
      status: InvitationStatus.fromWire(row['status'] as String?) ??
          InvitationStatus.pending,
    );
  }

  Invitation _fromRpcRow(Map<String, dynamic> row) => Invitation(
        id: row['id'] as String,
        candidateName: row['candidate_name'] as String? ?? '',
        candidateEmail: row['candidate_email'] as String? ?? '',
        roleId: row['role_id'] as String,
        code: row['code'] as String,
        createdAt: DateTime.parse(row['created_at'] as String),
        status: InvitationStatus.fromWire(row['status'] as String?) ??
            InvitationStatus.pending,
      );
}
