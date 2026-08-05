import 'package:cognihire/core/claims/claim_audit.dart';
import 'package:cognihire/core/invitations/invitation.dart';
import 'package:cognihire/core/invitations/invitation_store.dart';
import 'package:cognihire/core/persistence/audit_store.dart';
import 'package:cognihire/core/roles/role.dart';
import 'package:cognihire/core/roles/role_store.dart';
import 'package:cognihire/core/workspace/workspace_loader.dart';
import 'package:cognihire/features/invitations/invitations_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Flutter's default test surface is 800x600, which is narrower than the
  // real app's minimum window (1280x720) and trips ShellPage's compact
  // (stacked title-over-actions) layout — a layout the header, with three
  // actions since bulk invite, genuinely does not fit in 600px of height.
  // Matches the size other full-screen tests in this suite already use.
  void setRealisticSize(WidgetTester tester) {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Widget screenWith(
    RoleStore roleStore,
    InvitationStore invitationStore, {
    AuditStore? auditStore,
  }) =>
      MaterialApp(
        home: Scaffold(
          body: InvitationsScreen(
            invitationStore: invitationStore,
            roleStore: roleStore,
            loadSessions: () => loadWorkspace(auditStore ?? InMemoryAuditStore()),
          ),
        ),
      );

  ClaimAudit emptyAudit() => ClaimAudit(
        findings: const [],
        sessionStart: DateTime(2026, 8, 5, 9),
        sessionEnd: DateTime(2026, 8, 5, 9, 20),
        identityAttempts: const [],
      );

  testWidgets('prompts to define a role first when there are none',
      (tester) async {
    setRealisticSize(tester);
    await tester.pumpWidget(
      screenWith(InMemoryRoleStore(), InMemoryInvitationStore()),
    );
    await tester.pumpAndSettle();

    expect(find.text('Define a role first'), findsOneWidget);
  });

  testWidgets('invites a candidate and shows their redeemable code',
      (tester) async {
    setRealisticSize(tester);
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

  testWidgets('a pending invitation shows its code, not a report link',
      (tester) async {
    setRealisticSize(tester);
    final roleStore = InMemoryRoleStore();
    await roleStore.saveRole(Role(
      id: 'r1',
      title: 'Senior Backend',
      requiredSkills: const [],
      createdAt: DateTime(2026, 1, 1),
    ));
    final invitationStore = InMemoryInvitationStore();
    await invitationStore.saveInvitation(Invitation(
      id: 'inv-1',
      candidateName: 'Jordan Rivera',
      roleId: 'r1',
      code: 'ABC123',
      createdAt: DateTime(2026, 8, 1),
    ));

    await tester.pumpWidget(screenWith(roleStore, invitationStore));
    await tester.pumpAndSettle();

    expect(find.text('ABC123'), findsOneWidget);
    expect(find.text('View report'), findsNothing);
  });

  testWidgets(
      'an accepted invitation with no session yet shows a waiting status',
      (tester) async {
    setRealisticSize(tester);
    final roleStore = InMemoryRoleStore();
    await roleStore.saveRole(Role(
      id: 'r1',
      title: 'Senior Backend',
      requiredSkills: const [],
      createdAt: DateTime(2026, 1, 1),
    ));
    final invitationStore = InMemoryInvitationStore();
    await invitationStore.saveInvitation(Invitation(
      id: 'inv-1',
      candidateName: 'Jordan Rivera',
      roleId: 'r1',
      code: 'ABC123',
      createdAt: DateTime(2026, 8, 1),
      status: InvitationStatus.accepted,
    ));

    await tester.pumpWidget(screenWith(roleStore, invitationStore));
    await tester.pumpAndSettle();

    expect(find.text('Redeemed — awaiting interview'), findsOneWidget);
    expect(find.text('View report'), findsNothing);
  });

  testWidgets(
      'once the candidate has a stored session, HR gets a direct link to it',
      (tester) async {
    setRealisticSize(tester);
    final roleStore = InMemoryRoleStore();
    await roleStore.saveRole(Role(
      id: 'r1',
      title: 'Senior Backend',
      requiredSkills: const [],
      createdAt: DateTime(2026, 1, 1),
    ));
    final invitationStore = InMemoryInvitationStore();
    await invitationStore.saveInvitation(Invitation(
      id: 'inv-1',
      candidateName: 'Jordan Rivera',
      roleId: 'r1',
      code: 'ABC123',
      createdAt: DateTime(2026, 8, 1),
      status: InvitationStatus.accepted,
    ));

    final auditStore = InMemoryAuditStore();
    // Matches SessionDraft.sessionTitle's "name — role" shape for a
    // role-bound session, which is how HR and the candidate's session end up
    // filed under the same label without either side referencing the other.
    await auditStore.saveAudit(emptyAudit(), label: 'Jordan Rivera — Senior Backend');

    await tester.pumpWidget(screenWith(roleStore, invitationStore, auditStore: auditStore));
    await tester.pumpAndSettle();

    expect(find.text('View report'), findsOneWidget);
    expect(find.text('Redeemed — awaiting interview'), findsNothing);

    await tester.tap(find.text('View report'));
    await tester.pumpAndSettle();

    // Landed on the claim audit screen for that session.
    expect(find.text('Claim audit'), findsOneWidget);
  });
}
