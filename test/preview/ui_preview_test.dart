/// Renders screens to PNGs so the redesign can be looked at, not just asserted.
///
/// Not a golden *comparison* — nothing fails if pixels change. Run with
/// `flutter test --update-goldens test/preview` to regenerate the images.
@Tags(['preview'])
library;

import 'package:cognihire/core/design/app_theme.dart';
import 'package:cognihire/core/persistence/audit_store.dart';
import 'package:cognihire/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> shoot(
    WidgetTester tester,
    String name,
    Size size,
    ThemeData theme,
  ) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(MaterialApp(
      theme: theme,
      home: HomeScreen(
        store: InMemoryAuditStore(),
        storageLocation: '/tmp/cognihire',
        storageIsDurable: true,
      ),
    ));
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('$name.png'),
    );
  }

  testWidgets('home wide light', (t) async {
    await shoot(t, 'home_wide_light', const Size(1400, 900), AppTheme.light);
  });

  testWidgets('home wide dark', (t) async {
    await shoot(t, 'home_wide_dark', const Size(1400, 900), AppTheme.dark);
  });

  testWidgets('home compact', (t) async {
    await shoot(t, 'home_compact', const Size(420, 860), AppTheme.light);
  });
}
