import 'package:cognihire/ui/patterns.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regression test for a real crash hit running the app: TimelineEntry (used
/// on the Candidates and Dashboard screens) laid its connecting rule out with
/// `Expanded` inside a `Row` that a vertical `ListView`/`SingleChildScrollView`
/// hands unbounded height — "RenderFlex children have non-zero flex but
/// incoming height constraints are unbounded". Reproduced here exactly as the
/// real screens use it: multiple entries in a scrollable column. If the
/// layout bug regresses, `pumpAndSettle` reports the FlutterError and this
/// test fails — no separate assertion needed for that part.
void main() {
  testWidgets('renders inside a vertical scroll view without a layout error',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ListView(
          children: [
            for (var i = 0; i < 3; i++)
              TimelineEntry(
                title: 'Event $i',
                meta: '2026-08-05',
                body: 'Some detail about event $i.',
                isLast: i == 2,
              ),
          ],
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Event 0'), findsOneWidget);
    expect(find.text('Event 2'), findsOneWidget);
  });
}
