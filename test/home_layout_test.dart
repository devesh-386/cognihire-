/// Regression test for task 0.6 — the home screen must not overflow on a narrow
/// window.
///
/// The rest of the screen suite resizes the viewport to 1280×900 in setUp, which
/// is exactly what hid this bug: two Rows held unbounded Text and only fit
/// because the window was made wide enough for their natural width. This test
/// deliberately does NOT resize up — it pins a small window and asserts the
/// layout survives, in both the transient loading state and the settled state.
library;

import 'package:cognihire/core/design/app_theme.dart';
import 'package:cognihire/core/persistence/audit_store.dart';
import 'package:cognihire/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget narrowHome() => MaterialApp(
        theme: AppTheme.light,
        home: HomeScreen(
          store: InMemoryAuditStore(),
          storageLocation: '/tmp/cognihire',
          storageIsDurable: true,
        ),
      );

  void useSize(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  testWidgets('does not overflow at 360×640 — loading then settled',
      (tester) async {
    useSize(tester, const Size(360, 640));

    await tester.pumpWidget(narrowHome());
    // First frame shows the "Checking for a saved reference face…" card.
    expect(tester.takeException(), isNull,
        reason: 'loading state overflowed on a narrow window');

    await tester.pumpAndSettle();
    // Settled: masthead + "No reference face enrolled" card.
    expect(tester.takeException(), isNull,
        reason: 'settled state overflowed on a narrow window');
  });

  testWidgets('does not overflow at an even narrower 300 px', (tester) async {
    useSize(tester, const Size(300, 640));
    await tester.pumpWidget(narrowHome());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
