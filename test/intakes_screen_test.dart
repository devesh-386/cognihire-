import 'package:cognihire/core/intakes/intake.dart';
import 'package:cognihire/core/intakes/intake_store.dart';
import 'package:cognihire/core/roles/role.dart';
import 'package:cognihire/features/intakes/intakes_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final role = Role(
    id: 'role-1',
    title: 'Backend Engineer',
    requiredSkills: const ['PostgreSQL'],
    createdAt: DateTime(2026, 1, 1),
  );

  Widget screenFor(IntakeStore store) => MaterialApp(
        home: IntakesScreen(role: role, intakeStore: store),
      );

  testWidgets('shows an empty state with no intakes yet', (tester) async {
    await tester.pumpWidget(screenFor(InMemoryIntakeStore()));
    await tester.pumpAndSettle();

    expect(find.text('No intakes yet'), findsOneWidget);
  });

  testWidgets('creating an intake shows it in the list', (tester) async {
    final store = InMemoryIntakeStore();
    await tester.pumpWidget(screenFor(store));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'New intake').first);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'August 2026 Intake');
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();

    expect(find.text('August 2026 Intake'), findsOneWidget);
    expect(find.text('draft'), findsOneWidget);
  });

  testWidgets('activating a draft intake updates its status tag', (tester) async {
    final store = InMemoryIntakeStore();
    await store.create(roleId: role.id, name: 'August 2026 Intake');

    await tester.pumpWidget(screenFor(store));
    await tester.pumpAndSettle();

    expect(find.text('draft'), findsOneWidget);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Activate'));
    await tester.pumpAndSettle();

    expect(find.text('active'), findsOneWidget);
    expect(find.text('draft'), findsNothing);
  });

  testWidgets('a closed intake offers no further status actions', (tester) async {
    final store = InMemoryIntakeStore();
    final intake = await store.create(roleId: role.id, name: 'August 2026 Intake');
    await store.updateStatus(intake.id, IntakeStatus.closed);

    await tester.pumpWidget(screenFor(store));
    await tester.pumpAndSettle();

    expect(find.text('closed'), findsOneWidget);
    expect(find.byType(OutlinedButton), findsNothing);
  });
}
