import 'package:cognihire/core/auth/principal.dart';
import 'package:cognihire/core/auth/user_role.dart';
import 'package:cognihire/core/invitations/invitation.dart';
import 'package:cognihire/core/invitations/invitation_store.dart';
import 'package:cognihire/features/auth/sign_in_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget screenWith(
    InvitationStore store,
    void Function(Principal, Invitation?) onSignIn,
  ) =>
      MaterialApp(
        home: SignInScreen(invitationStore: store, onSignIn: onSignIn),
      );

  group('SignInScreen', () {
    testWidgets('offers recruiter entry and a candidate code field',
        (tester) async {
      await tester.pumpWidget(screenWith(InMemoryInvitationStore(), (_, _) {}));

      expect(find.text('Continue as Recruiter'), findsOneWidget);
      expect(find.text('Continue as Candidate'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Invitation code'), findsOneWidget);
    });

    testWidgets('choosing recruiter yields a recruiter principal in an org',
        (tester) async {
      Principal? chosen;
      await tester.pumpWidget(
          screenWith(InMemoryInvitationStore(), (p, i) => chosen = p));

      await tester.tap(find.text('Enter as Recruiter'));
      await tester.pump();

      expect(chosen, isNotNull);
      expect(chosen!.role, UserRole.recruiter);
      // Recruiters belong to an organisation; candidates do not.
      expect(chosen!.organisationId, isNotNull);
    });

    testWidgets('a valid code signs the invited candidate in and binds them',
        (tester) async {
      final store = InMemoryInvitationStore();
      await store.saveInvitation(Invitation(
        id: 'inv-1',
        candidateName: 'Jordan Rivera',
        roleId: 'role-backend',
        code: 'ABC123',
        createdAt: DateTime(2026, 8, 1),
      ));

      Principal? chosen;
      Invitation? boundInvitation;
      await tester.pumpWidget(screenWith(store, (p, i) {
        chosen = p;
        boundInvitation = i;
      }));

      await tester.enterText(
        find.widgetWithText(TextField, 'Invitation code'),
        'abc123',
      );
      await tester.tap(find.text('Enter interview'));
      // Not pumpAndSettle: in this isolated test nothing swaps SignInScreen
      // out on success, so its (now-pointless) spinner would animate forever.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(chosen, isNotNull);
      expect(chosen!.role, UserRole.candidate);
      expect(chosen!.displayName, 'Jordan Rivera');
      expect(chosen!.organisationId, isNull);
      expect(boundInvitation, isNotNull);
      expect(boundInvitation!.roleId, 'role-backend');

      // Redeeming marks the invitation accepted so the code cannot be reused.
      expect(await store.findRedeemable('ABC123'), isNull);
    });

    testWidgets('an unknown code shows an error and does not sign in',
        (tester) async {
      var signedIn = false;
      await tester.pumpWidget(screenWith(
        InMemoryInvitationStore(),
        (_, _) => signedIn = true,
      ));

      await tester.enterText(
        find.widgetWithText(TextField, 'Invitation code'),
        'NOPE99',
      );
      await tester.tap(find.text('Enter interview'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(signedIn, isFalse);
      expect(
        find.text('That code is not recognised, or has already been used.'),
        findsOneWidget,
      );
    });
  });
}
