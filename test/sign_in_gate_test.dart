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
    testWidgets('offers recruiter entry and a candidate code field', (
      tester,
    ) async {
      await tester.pumpWidget(screenWith(InMemoryInvitationStore(), (_, _) {}));

      expect(find.text('Continue as Recruiter'), findsOneWidget);
      expect(find.text('Continue as Candidate'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Invitation code'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Work email'), findsOneWidget);
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
      'registering a new recruiter provisions an organisation and signs in',
      (tester) async {
        setRealisticSize(tester);
        final authStore = InMemoryAuthStore();

        Principal? chosen;
        await tester.pumpWidget(
          screenWith(
            InMemoryInvitationStore(),
            (p, i) => chosen = p,
            authStore: authStore,
            provisionOrganization: (name) async => Principal(
              id: 'user-1',
              email: 'new@meridianhealth.example',
              role: UserRole.recruiter,
              organisationId: 'org-$name',
            ),
          ),
        );

        await tester.tap(find.text('New organisation? Create an account'));
        await tester.pump();

        await tester.enterText(
          find.widgetWithText(TextField, 'Work email'),
          'new@meridianhealth.example',
        );
        await tester.enterText(
          find.widgetWithText(TextField, 'Password'),
          'a very long passphrase',
        );
        await tester.enterText(
          find.widgetWithText(TextField, 'Organisation name'),
          'meridian-health',
        );
        await tester.tap(find.text('Create account'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        expect(chosen, isNotNull);
        expect(chosen!.organisationId, 'org-meridian-health');
      },
    );

    testWidgets('a valid code signs the invited candidate in and binds them', (
      tester,
    ) async {
      final store = InMemoryInvitationStore();
      await store.saveInvitation(
        Invitation(
          id: 'inv-1',
          candidateName: 'Jordan Rivera',
          roleId: 'role-backend',
          code: 'ABC123',
          createdAt: DateTime(2026, 8, 1),
        ),
      );

      Principal? chosen;
      Invitation? boundInvitation;
      await tester.pumpWidget(
        screenWith(store, (p, i) {
          chosen = p;
          boundInvitation = i;
        }),
      );

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

    testWidgets('an unknown code shows an error and does not sign in', (
      tester,
    ) async {
      var signedIn = false;
      await tester.pumpWidget(
        screenWith(InMemoryInvitationStore(), (_, _) => signedIn = true),
      );

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

    testWidgets(
        'the candidate web build (showRecruiterOption: false) has no HR entry',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: SignInScreen(
          invitationStore: InMemoryInvitationStore(),
          authStore: InMemoryAuthStore(),
          showRecruiterOption: false,
          onSignIn: (_, _) {},
        ),
      ));

      expect(find.text('Continue as Recruiter'), findsNothing);
      expect(find.widgetWithText(TextField, 'Work email'), findsNothing);
      expect(find.widgetWithText(TextField, 'Invitation code'), findsOneWidget);
    });
  });
}
