import 'package:cognihire/core/auth/in_memory_auth_store.dart';
import 'package:cognihire/core/auth/principal.dart';
import 'package:cognihire/core/auth/user_role.dart';
import 'package:cognihire/core/invitations/invitation.dart';
import 'package:cognihire/core/invitations/invitation_store.dart';
import 'package:cognihire/features/auth/sign_in_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Flutter's default 800x600 test surface is shorter than the recruiter
  // card's sign-in/register form (email + password + org name + errors +
  // button + toggle link), so a control below the fold fails to hit-test.
  // Matches the convention already used in role_navigation_test.dart etc.
  void setRealisticSize(WidgetTester tester) {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Widget screenWith(
    InvitationStore invitationStore,
    void Function(Principal, Invitation?) onSignIn, {
    InMemoryAuthStore? authStore,
    Future<Principal?> Function(String)? provisionOrganization,
  }) => MaterialApp(
    home: SignInScreen(
      invitationStore: invitationStore,
      authStore: authStore ?? InMemoryAuthStore(),
      provisionOrganization: provisionOrganization,
      onSignIn: onSignIn,
    ),
  );

  group('SignInScreen', () {
    testWidgets('offers recruiter sign-in — no candidate entry point', (
      tester,
    ) async {
      await tester.pumpWidget(screenWith(InMemoryInvitationStore(), (_, _) {}));

      expect(find.widgetWithText(TextField, 'Work email'), findsOneWidget);
      expect(find.text('Continue as Candidate'), findsNothing);
      expect(find.widgetWithText(TextField, 'Invitation code'), findsNothing);
    });

    testWidgets(
      'signing in with a known recruiter account yields their principal',
      (tester) async {
        setRealisticSize(tester);
        final authStore = InMemoryAuthStore.withAccount(
          email: 'priya@meridianhealth.example',
          password: 'a very long passphrase',
          role: UserRole.recruiter,
          organisationId: 'org-meridian-health',
        );

        Principal? chosen;
        await tester.pumpWidget(
          screenWith(
            InMemoryInvitationStore(),
            (p, i) => chosen = p,
            authStore: authStore,
          ),
        );

        await tester.enterText(
          find.widgetWithText(TextField, 'Work email'),
          'priya@meridianhealth.example',
        );
        await tester.enterText(
          find.widgetWithText(TextField, 'Password'),
          'a very long passphrase',
        );
        await tester.tap(find.text('Enter as Recruiter'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        expect(chosen, isNotNull);
        expect(chosen!.role, UserRole.recruiter);
        expect(chosen!.organisationId, 'org-meridian-health');
      },
    );

    testWidgets('a wrong password shows an error and does not sign in', (
      tester,
    ) async {
      setRealisticSize(tester);
      final authStore = InMemoryAuthStore.withAccount(
        email: 'priya@meridianhealth.example',
        password: 'a very long passphrase',
        role: UserRole.recruiter,
      );

      var signedIn = false;
      await tester.pumpWidget(
        screenWith(
          InMemoryInvitationStore(),
          (_, _) => signedIn = true,
          authStore: authStore,
        ),
      );

      await tester.enterText(
        find.widgetWithText(TextField, 'Work email'),
        'priya@meridianhealth.example',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Password'),
        'wrong password entirely',
      );
      await tester.tap(find.text('Enter as Recruiter'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(signedIn, isFalse);
      expect(find.text('Incorrect email or password.'), findsOneWidget);
    });

    testWidgets(
      'choosing to register swaps the form for the browser-registration CTA',
      (tester) async {
        setRealisticSize(tester);
        await tester.pumpWidget(
          screenWith(InMemoryInvitationStore(), (_, _) {}),
        );

        await tester.tap(find.text('New organisation? Create an account'));
        await tester.pump();

        // Registration now happens on the web portal — no in-app password/org
        // fields, just a link out and an "already have an account" way back.
        expect(find.widgetWithText(TextField, 'Work email'), findsNothing);
        expect(find.widgetWithText(TextField, 'Organisation name'), findsNothing);
        expect(find.text('Create account on cognihire.online'), findsOneWidget);
        expect(find.text('Already have an account? Sign in'), findsOneWidget);
      },
    );
  });
}
