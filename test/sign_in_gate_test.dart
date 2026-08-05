import 'package:cognihire/core/auth/principal.dart';
import 'package:cognihire/core/auth/user_role.dart';
import 'package:cognihire/features/auth/sign_in_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SignInScreen', () {
    testWidgets('offers both roles as entry points', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: SignInScreen(onSignIn: (_) {}),
      ));

      expect(find.text('Continue as Recruiter'), findsOneWidget);
      expect(find.text('Continue as Candidate'), findsOneWidget);
    });

    testWidgets('choosing recruiter yields a recruiter principal in an org',
        (tester) async {
      Principal? chosen;
      await tester.pumpWidget(MaterialApp(
        home: SignInScreen(onSignIn: (p) => chosen = p),
      ));

      await tester.tap(find.text('Enter as Recruiter'));
      await tester.pump();

      expect(chosen, isNotNull);
      expect(chosen!.role, UserRole.recruiter);
      // Recruiters belong to an organisation; candidates do not.
      expect(chosen!.organisationId, isNotNull);
    });

    testWidgets('choosing candidate yields a candidate principal with no org',
        (tester) async {
      Principal? chosen;
      await tester.pumpWidget(MaterialApp(
        home: SignInScreen(onSignIn: (p) => chosen = p),
      ));

      await tester.tap(find.text('Enter as Candidate'));
      await tester.pump();

      expect(chosen, isNotNull);
      expect(chosen!.role, UserRole.candidate);
      expect(chosen!.organisationId, isNull);
    });
  });
}
