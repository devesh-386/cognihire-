import 'package:cognihire/core/auth/principal.dart';
import 'package:cognihire/core/auth/user_role.dart';
import 'package:cognihire/core/invitations/invitation.dart';
import 'package:cognihire/core/invitations/invitation_store.dart';
import 'package:cognihire/core/persistence/audit_store.dart';
import 'package:cognihire/core/roles/role.dart';
import 'package:cognihire/core/roles/role_store.dart';
import 'package:cognihire/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Proves the "New session" screen is pre-filled from a redeemed invitation —
/// a candidate who entered via a code should not have to find their own role
/// in a dropdown, and the candidate-reference field must actually display the
/// name it was bound to (a plain TextField silently would not).
void main() {
  testWidgets('candidate reference and role are pre-filled from the invitation',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final roleStore = InMemoryRoleStore();
    await roleStore.saveRole(Role(
      id: 'role-backend',
      title: 'Senior Backend',
      requiredSkills: const ['Go'],
      createdAt: DateTime(2026, 1, 1),
    ));

    final invitation = Invitation(
      id: 'inv-1',
      candidateName: 'Jordan Rivera',
      roleId: 'role-backend',
      code: 'ABC123',
      createdAt: DateTime(2026, 8, 1),
    );

    await tester.pumpWidget(MaterialApp(
      home: HomeScreen(
        store: InMemoryAuditStore(),
        roleStore: roleStore,
        invitationStore: InMemoryInvitationStore(),
        storageLocation: '/tmp/cognihire',
        storageIsDurable: true,
        principal: const Principal(
          id: 'candidate-inv-1',
          email: 'jordan@example.com',
          role: UserRole.candidate,
          displayName: 'Jordan Rivera',
        ),
        onSignOut: () {},
        redeemedInvitation: invitation,
      ),
    ));
    await tester.pumpAndSettle();

    // "New session" is the candidate's landing destination for their flow.
    await tester.tap(find.text('New session').first);
    await tester.pumpAndSettle();

    expect(find.text('Jordan Rivera'), findsWidgets);
    expect(find.text('Senior Backend'), findsOneWidget);
  });
}
