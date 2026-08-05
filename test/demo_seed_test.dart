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

    test('does not seed when an invitation already exists', () async {
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

      final roles = await roleStore.listRoles();
      expect(roles.roles, isEmpty);
    });
  });
}
