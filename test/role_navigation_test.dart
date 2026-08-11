import 'package:cognihire/core/auth/principal.dart';
import 'package:cognihire/core/auth/user_role.dart';
import 'package:cognihire/core/persistence/audit_store.dart';
import 'package:cognihire/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Proves the two signed-in experiences show genuinely different navigation —
/// the point of the two-login split. HR manages roles/candidates; the candidate
/// runs their own interview flow. Neither sees the other's tabs.
void main() {
  const hr = Principal(
    id: 'hr-1',
    email: 'hr@acme.example',
    role: UserRole.recruiter,
    organisationId: 'org-acme',
  );
  const candidate = Principal(
    id: 'cand-1',
    email: 'c@example.com',
    role: UserRole.candidate,
  );

  Widget appFor(Principal principal) => MaterialApp(
        home: HomeScreen(
          store: InMemoryAuditStore(),
          storageLocation: '/tmp/cognihire',
          storageIsDurable: true,
          principal: principal,
          onSignOut: () {},
        ),
      );

  testWidgets('HR sees recruiter tabs, not the candidate interview flow',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(appFor(hr));
    await tester.pumpAndSettle();

    expect(find.text('Roles'), findsWidgets);
    expect(find.text('Candidates'), findsWidgets);
    expect(find.text('Resume analysis'), findsNothing);
    expect(find.text('New session'), findsNothing);
  });

  testWidgets('both roles keep Settings and Reports', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    for (final p in [hr, candidate]) {
      await tester.pumpWidget(appFor(p));
      await tester.pumpAndSettle();
      expect(find.text('Settings'), findsWidgets, reason: '${p.role} settings');
      expect(find.text('Reports'), findsWidgets, reason: '${p.role} reports');
    }
  });
}
