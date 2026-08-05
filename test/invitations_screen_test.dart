import 'package:cognihire/core/invitations/invitation_store.dart';
import 'package:cognihire/core/roles/role.dart';
import 'package:cognihire/core/roles/role_store.dart';
import 'package:cognihire/features/invitations/invitations_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget screenWith(RoleStore roleStore, InvitationStore invitationStore) =>
      MaterialApp(
        home: Scaffold(
          body: InvitationsScreen(
            invitationStore: invitationStore,
            roleStore: roleStore,
          ),
        ),
      );

  testWidgets('prompts to define a role first when there are none',
      (tester) async {
    await tester.pumpWidget(
      screenWith(InMemoryRoleStore(), InMemoryInvitationStore()),
    );
    await tester.pumpAndSettle();

    expect(find.text('Define a role first'), findsOneWidget);
  });

  testWidgets('invites a candidate and shows their redeemable code',
      (tester) async {
    final roleStore = InMemoryRoleStore();
    await roleStore.saveRole(Role(
      id: 'r1',
      title: 'Senior Backend',
      requiredSkills: const ['Go'],
      createdAt: DateTime(2026, 1, 1),
    ));
    final invitationStore = InMemoryInvitationStore();

    await tester.pumpWidget(screenWith(roleStore, invitationStore));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Invite candidate').first);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'Jordan Rivera');
    await tester.tap(find.text('Create invitation'));
    await tester.pumpAndSettle();

    expect(find.text('Jordan Rivera'), findsOneWidget);
    expect(find.text('Senior Backend'), findsOneWidget);

    final index = await invitationStore.listInvitations();
    expect(index.invitations, hasLength(1));
    expect(index.invitations.single.candidateName, 'Jordan Rivera');
    expect(index.invitations.single.roleId, 'r1');
    expect(index.invitations.single.code, hasLength(6));
  });
}
