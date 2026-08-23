/// Supabase-backed [RoleStore] (Ticket 10) — replaces the local JSON store
/// for the HR app now that roles live in the shared `cognihire` project
/// (organization-scoped by RLS, see `cognihire_minimal_schema`).
library;

import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

import 'role.dart';
import 'role_store.dart';

class SupabaseRoleStore implements RoleStore {
  SupabaseRoleStore(this._client);

  final supabase.SupabaseClient _client;

  /// Read fresh on every call rather than cached, so a session established
  /// (or a metadata refresh after [provisionOrganization]) after construction
  /// is picked up without rebuilding the store.
  ///
  /// From appMetadata, not userMetadata — see
  /// invitation_store_supabase.dart's identical fix and
  /// supabase_auth_store.dart's principalFromUser for why (SEC-001).
  String? get _organizationId =>
      _client.auth.currentUser?.appMetadata['organization_id'] as String?;

  @override
  Future<RoleIndex> listRoles() async {
    try {
      final rows = await _client
          .from('roles')
          .select()
          .order('created_at', ascending: false);
      final roles =
          (rows as List).map((row) => _fromRow(row as Map<String, dynamic>)).toList();
      return RoleIndex(roles: roles, problem: null);
    } catch (error) {
      return RoleIndex(roles: const [], problem: error.toString());
    }
  }

  @override
  Future<void> saveRole(Role role) async {
    final organizationId = _organizationId;
    if (organizationId == null) {
      throw StateError(
        'No organization on the signed-in account — cannot save a role.',
      );
    }
    await _client.from('roles').upsert({
      'id': role.id,
      'organization_id': organizationId,
      'title': role.title,
      'required_skills': role.requiredSkills,
      'desirable_skills': role.desirableSkills,
      'notes': role.notes,
      'created_at': role.createdAt.toIso8601String(),
    });
  }

  @override
  Future<void> deleteRole(String id) async {
    await _client.from('roles').delete().eq('id', id);
  }

  Role _fromRow(Map<String, dynamic> row) => Role(
        id: row['id'] as String,
        title: row['title'] as String,
        requiredSkills: List<String>.from(row['required_skills'] as List? ?? const []),
        desirableSkills:
            List<String>.from(row['desirable_skills'] as List? ?? const []),
        notes: row['notes'] as String? ?? '',
        createdAt: DateTime.parse(row['created_at'] as String),
      );
}
