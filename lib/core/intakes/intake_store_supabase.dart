/// Supabase-backed [IntakeStore] — same pattern as [SupabaseRoleStore]:
/// direct table access, org-scoped by RLS (infra/migrations/0008_intakes.sql),
/// with the organization_id/role_id consistency invariant enforced by a
/// database trigger rather than trusted client-side.
library;

import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

import 'intake.dart';
import 'intake_store.dart';

class SupabaseIntakeStore implements IntakeStore {
  SupabaseIntakeStore(this._client);

  final supabase.SupabaseClient _client;

  String? get _organizationId =>
      _client.auth.currentUser?.userMetadata?['organization_id'] as String?;

  @override
  Future<List<Intake>> listForRole(String roleId) async {
    final rows = await _client
        .from('intakes')
        .select()
        .eq('role_id', roleId)
        .order('created_at', ascending: false);
    return (rows as List)
        .map((row) => _fromRow(row as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<Intake> create({required String roleId, required String name}) async {
    final organizationId = _organizationId;
    if (organizationId == null) {
      throw StateError(
        'No organization on the signed-in account — cannot create an intake.',
      );
    }
    // No client-generated id: organization_id/role_id consistency is
    // enforced by the intakes_role_org_consistency trigger, which needs the
    // insert to go through normally rather than an upsert with a
    // pre-decided id (there's nothing to conflict on here yet, unlike
    // roles' edit-in-place flow).
    final row = await _client
        .from('intakes')
        .insert({
          'organization_id': organizationId,
          'role_id': roleId,
          'name': name,
        })
        .select()
        .single();
    return _fromRow(row);
  }

  @override
  Future<void> updateStatus(String intakeId, IntakeStatus status) async {
    final fields = <String, dynamic>{'status': status.wireValue};
    if (status == IntakeStatus.closed) {
      fields['closed_at'] = DateTime.now().toIso8601String();
    }
    await _client.from('intakes').update(fields).eq('id', intakeId);
  }

  Intake _fromRow(Map<String, dynamic> row) => Intake(
        id: row['id'] as String,
        organizationId: row['organization_id'] as String,
        roleId: row['role_id'] as String,
        name: row['name'] as String,
        status: IntakeStatus.fromWire(row['status'] as String),
        createdAt: DateTime.parse(row['created_at'] as String),
        googleFormId: row['google_form_id'] as String?,
        applicationUrl: row['application_url'] as String?,
        closedAt: row['closed_at'] == null
            ? null
            : DateTime.parse(row['closed_at'] as String),
      );
}
