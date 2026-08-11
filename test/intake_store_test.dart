import 'package:cognihire/core/intakes/intake.dart';
import 'package:cognihire/core/intakes/intake_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// InMemoryIntakeStore's contract — the same one SupabaseIntakeStore fulfils
/// against the real intakes table (org/role consistency and RLS are the
/// database's job there, exercised separately against the live project).
void main() {
  test('a new intake starts in draft status', () async {
    final store = InMemoryIntakeStore();
    final intake = await store.create(roleId: 'role-1', name: 'August 2026');

    expect(intake.status, IntakeStatus.draft);
    expect(intake.roleId, 'role-1');
    expect(intake.name, 'August 2026');
  });

  test('listForRole only returns intakes for that role', () async {
    final store = InMemoryIntakeStore();
    await store.create(roleId: 'role-1', name: 'August 2026');
    await store.create(roleId: 'role-2', name: 'A different role entirely');

    final forRole1 = await store.listForRole('role-1');
    expect(forRole1, hasLength(1));
    expect(forRole1.single.name, 'August 2026');
  });

  test('two intakes for the same role stay distinct campaigns', () async {
    final store = InMemoryIntakeStore();
    await store.create(roleId: 'role-1', name: 'August 2026 Intake');
    await store.create(roleId: 'role-1', name: 'October 2026 Intake');

    final intakes = await store.listForRole('role-1');
    expect(intakes.map((i) => i.name), containsAll(['August 2026 Intake', 'October 2026 Intake']));
    expect(intakes.map((i) => i.id).toSet(), hasLength(2));
  });

  test('updateStatus moves an intake to active', () async {
    final store = InMemoryIntakeStore();
    final intake = await store.create(roleId: 'role-1', name: 'August 2026');

    await store.updateStatus(intake.id, IntakeStatus.active);

    final reloaded = await store.listForRole('role-1');
    expect(reloaded.single.status, IntakeStatus.active);
  });

  test('closing an intake records closedAt', () async {
    final store = InMemoryIntakeStore();
    final intake = await store.create(roleId: 'role-1', name: 'August 2026');

    await store.updateStatus(intake.id, IntakeStatus.closed);

    final reloaded = await store.listForRole('role-1');
    expect(reloaded.single.status, IntakeStatus.closed);
    expect(reloaded.single.closedAt, isNotNull);
  });

  test('IntakeStatus.fromWire refuses an unrecognised value rather than guessing', () {
    expect(() => IntakeStatus.fromWire('hired'), throwsFormatException);
  });
}
