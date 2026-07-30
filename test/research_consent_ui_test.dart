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

  testWidgets('the research-consent checkbox is unchecked by default',
      (tester) async {
    await tester.pumpWidget(home());
    await tester.pumpAndSettle();

    final checkbox = tester.widget<CheckboxListTile>(
      find.byType(CheckboxListTile),
    );
    expect(checkbox.value, isFalse);
  });

  testWidgets('tapping it toggles the value', (tester) async {
    await tester.pumpWidget(home());
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
    await tester.pumpWidget(home());
    await tester.pumpAndSettle();

    expect(find.textContaining('identity verification, which always runs'),
        findsOneWidget);
  });
}
