import 'package:cognihire/core/design/app_theme.dart';
import 'package:cognihire/core/persistence/audit_store.dart';
import 'package:cognihire/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget home() => MaterialApp(
        theme: AppTheme.light,
        home: HomeScreen(
          store: InMemoryAuditStore(),
          storageLocation: '/tmp/cognihire',
          storageIsDurable: true,
        ),
      );

  setUp(() {
    final view = TestWidgetsFlutterBinding.instance.platformDispatcher
        .implicitView!;
    view.physicalSize = const Size(1280, 900);
    view.devicePixelRatio = 1.0;
    addTearDown(() {
      view.resetPhysicalSize();
      view.resetDevicePixelRatio();
    });
  });

  // The setup form — where the research-consent checkbox lives — is now the
  // "New session" destination behind the shell's rail rather than the whole
  // app's home content, so every test here opens it first.
  Future<void> openSetup(WidgetTester tester) async {
    await tester.pumpWidget(home());
    await tester.pumpAndSettle();
    // Two things now read "New session": the rail's own CTA button and the
    // destination label beside it. The destination (the last match) is the
    // reliable tap target in a test environment.
    await tester.tap(find.text('New session').last);
    await tester.pumpAndSettle();
  }

  testWidgets('the research-consent checkbox is unchecked by default',
      (tester) async {
    await openSetup(tester);

    final checkbox = tester.widget<CheckboxListTile>(
      find.byType(CheckboxListTile),
    );
    expect(checkbox.value, isFalse);
  });

  testWidgets('tapping it toggles the value', (tester) async {
    await openSetup(tester);

    await tester.ensureVisible(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();

    final checkbox = tester.widget<CheckboxListTile>(
      find.byType(CheckboxListTile),
    );
    expect(checkbox.value, isTrue);
  });

  testWidgets('names identity verification as separate and always-on',
      (tester) async {
    await openSetup(tester);

    expect(find.textContaining('identity verification, which always runs'),
        findsOneWidget);
  });
}
