import 'package:cognihire/core/invitations/invitation.dart';
import 'package:cognihire/core/invitations/invitation_store.dart';
import 'package:cognihire/core/roles/role.dart';
import 'package:cognihire/core/roles/role_store.dart';
import 'package:cognihire/main.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pins the seeding contract this app relies on for a repeatable demo: seed
/// exactly once, and never touch either store if real work already exists in
/// it — a seed that silently overwrote or duplicated on top of a role someone
/// actually authored would be worse than no seed at all.
void main() {
  group('demo seeding contract', () {
    test('a fresh pair of empty stores gets one role and one invitation',
        () async {
      final roleStore = InMemoryRoleStore();
      final invitationStore = InMemoryInvitationStore();

      await seedDemoDataIfEmpty(roleStore, invitationStore);

      final roles = await roleStore.listRoles();
      final invitations = await invitationStore.listInvitations();
      expect(roles.roles, hasLength(1));
      expect(invitations.invitations, hasLength(1));
      expect(invitations.invitations.single.roleId, roles.roles.single.id);
      expect(invitations.invitations.single.code, 'DEMO01');
    });

    test('does not seed when a role already exists', () async {
      final roleStore = InMemoryRoleStore();
      await roleStore.saveRole(Role(
        id: 'real-role',
        title: 'Real role someone actually wrote',
        requiredSkills: const [],
        createdAt: DateTime(2026, 1, 1),
      ));
      final invitationStore = InMemoryInvitationStore();

      await seedDemoDataIfEmpty(roleStore, invitationStore);

      final invitations = await invitationStore.listInvitations();
      expect(invitations.invitations, isEmpty);
      final roles = await roleStore.listRoles();
      expect(roles.roles, hasLength(1));
      expect(roles.roles.single.id, 'real-role');
    });

    test('never touches an existing invitation, even a mismatched one',
        () async {
      // Edge case, not a real user flow (the UI requires a role to exist
      // before an invitation can be created), but the function must not
      // clobber real data regardless of how it got into this shape.
      final roleStore = InMemoryRoleStore();
      final invitationStore = InMemoryInvitationStore();
      await invitationStore.saveInvitation(Invitation(
        id: 'real-invitation',
        candidateName: 'Someone Real',
        roleId: 'whatever',
        code: 'REAL01',
        createdAt: DateTime(2026, 1, 1),
      ));

      await seedDemoDataIfEmpty(roleStore, invitationStore);

      final invitations = await invitationStore.listInvitations();
      expect(invitations.invitations, hasLength(1));
      expect(invitations.invitations.single.id, 'real-invitation');
      expect(invitations.invitations.single.code, 'REAL01');
    });

    test(
        'a second launch re-seeds the invitation, because InvitationStore is '
        'not durable, without duplicating the durable seed role', () async {
      // Simulates the real bug this contract exists to prevent: RoleStore
      // persists across launches, InvitationStore does not. A guard that only
      // checked "is the role store empty" would seed the role once and then
      // silently stop seeding the invitation on every later launch — the demo
      // code from the pitch would go dead after the very first run.
      final roleStore = InMemoryRoleStore();
      final invitationStore = InMemoryInvitationStore();

      await seedDemoDataIfEmpty(roleStore, invitationStore); // launch 1
      final rolesAfterFirst = await roleStore.listRoles();
      expect(rolesAfterFirst.roles, hasLength(1));

      final freshInvitationStore = InMemoryInvitationStore(); // new process
      await seedDemoDataIfEmpty(roleStore, freshInvitationStore); // launch 2

      final rolesAfterSecond = await roleStore.listRoles();
      expect(rolesAfterSecond.roles, hasLength(1),
          reason: 'the durable seed role must not be duplicated');
      expect(rolesAfterSecond.roles.single.id, rolesAfterFirst.roles.single.id);

      final invitationsAfterSecond =
          await freshInvitationStore.listInvitations();
      expect(invitationsAfterSecond.invitations, hasLength(1),
          reason: 'the code must work again on a fresh launch');
      expect(invitationsAfterSecond.invitations.single.code, 'DEMO01');
    });
  });
}
