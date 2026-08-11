/// Persistence for intakes. Abstract for the same reason [RoleStore] is —
/// tests and previews get an in-memory implementation, the running app gets
/// [SupabaseIntakeStore].
library;

import 'intake.dart';

abstract class IntakeStore {
  Future<List<Intake>> listForRole(String roleId);

  Future<Intake> create({required String roleId, required String name});

  Future<void> updateStatus(String intakeId, IntakeStatus status);
}

class InMemoryIntakeStore implements IntakeStore {
  final Map<String, Intake> _intakes = {};
  int _counter = 0;

  @override
  Future<List<Intake>> listForRole(String roleId) async {
    final rows = _intakes.values.where((i) => i.roleId == roleId).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return rows;
  }

  @override
  Future<Intake> create({required String roleId, required String name}) async {
    _counter += 1;
    final intake = Intake(
      id: 'intake-$_counter',
      organizationId: 'local',
      roleId: roleId,
      name: name,
      status: IntakeStatus.draft,
      createdAt: DateTime.now(),
    );
    _intakes[intake.id] = intake;
    return intake;
  }

  @override
  Future<void> updateStatus(String intakeId, IntakeStatus status) async {
    final existing = _intakes[intakeId];
    if (existing == null) return;
    _intakes[intakeId] = Intake(
      id: existing.id,
      organizationId: existing.organizationId,
      roleId: existing.roleId,
      name: existing.name,
      status: status,
      createdAt: existing.createdAt,
      googleFormId: existing.googleFormId,
      applicationUrl: existing.applicationUrl,
      closedAt: status == IntakeStatus.closed ? DateTime.now() : existing.closedAt,
    );
  }
}
