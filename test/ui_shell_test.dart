/// Tests for the shell and the shared component layer.
///
/// These exist for the same reason `screens_widget_test.dart` does: pure-Dart
/// tests are blind to a widget that throws the moment it builds, and this app
/// has already shipped one of those with a green suite. A component library is
/// the worst place to have that happen, because every screen inherits it.
///
/// The responsive assertions are the substantive ones. A layout that "works"
/// only at the size the test harness happens to default to is exactly the bug
/// that produced an 83px overflow here before.
library;

import 'package:cognihire/core/design/app_theme.dart';
import 'package:cognihire/ui/app_shell.dart';
import 'package:cognihire/ui/components.dart';
import 'package:cognihire/ui/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  void useSize(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  Widget wrap(Widget child, {ThemeData? theme}) => MaterialApp(
        theme: theme ?? AppTheme.light,
        home: child,
      );

  List<ShellDestination> destinations(List<String> built) => [
        ShellDestination(
          icon: Icons.play_circle_outline,
          selectedIcon: Icons.play_circle_fill,
          label: 'New session',
          builder: (_) {
            built.add('one');
            return const Center(child: Text('PAGE ONE'));
          },
        ),
        ShellDestination(
          icon: Icons.history_outlined,
          selectedIcon: Icons.history,
          label: 'Past sessions',
          builder: (_) {
            built.add('two');
            return const Center(child: Text('PAGE TWO'));
          },
        ),
      ];

  group('AppShell', () {
    testWidgets('shows a rail on a wide window and a bottom bar on a narrow one',
        (tester) async {
      useSize(tester, const Size(1400, 900));
      await tester.pumpWidget(wrap(AppShell(destinations: destinations([]))));
      await tester.pumpAndSettle();

      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);

      useSize(tester, const Size(480, 900));
      await tester.pumpWidget(wrap(AppShell(destinations: destinations([]))));
      await tester.pumpAndSettle();

      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byType(NavigationRail), findsNothing);
    });

    testWidgets('an unvisited destination is never built', (tester) async {
      useSize(tester, const Size(1400, 900));
      final built = <String>[];

      await tester.pumpWidget(wrap(AppShell(destinations: destinations(built))));
      await tester.pumpAndSettle();

      // The point of the lazy stack: opening the app must not pay for reading
      // the session store or mounting the telemetry sandbox.
      expect(built, contains('one'));
      expect(built, isNot(contains('two')));

      await tester.tap(find.text('Past sessions'));
      await tester.pumpAndSettle();

      expect(built, contains('two'));
      expect(find.text('PAGE TWO'), findsOneWidget);
    });

    testWidgets('a visited destination stays alive after switching away',
        (tester) async {
      useSize(tester, const Size(1400, 900));
      await tester.pumpWidget(wrap(AppShell(destinations: destinations([]))));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Past sessions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New session'));
      await tester.pumpAndSettle();

      // Still in the tree (offstage), so its scroll position and state survive.
      expect(find.text('PAGE TWO', skipOffstage: false), findsOneWidget);
      expect(find.text('PAGE ONE'), findsOneWidget);
    });

    testWidgets('survives a very narrow window without overflowing',
        (tester) async {
      useSize(tester, const Size(300, 620));
      await tester.pumpWidget(wrap(AppShell(destinations: destinations([]))));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders in dark theme', (tester) async {
      useSize(tester, const Size(1400, 900));
      await tester.pumpWidget(
        wrap(AppShell(destinations: destinations([])), theme: AppTheme.dark),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('ShellPage', () {
    testWidgets('renders title, subtitle and content, and scrolls',
        (tester) async {
      useSize(tester, const Size(1000, 600));
      await tester.pumpWidget(wrap(const Scaffold(
        body: ShellPage(
          title: 'Session setup',
          subtitle: 'Who this session is for',
          children: [SizedBox(height: 2000, child: Text('LONG BODY'))],
        ),
      )));
      await tester.pumpAndSettle();

      expect(find.text('Session setup'), findsOneWidget);
      expect(find.text('Who this session is for'), findsOneWidget);
      expect(find.byType(SingleChildScrollView), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('does not overflow at 320px with actions present',
        (tester) async {
      useSize(tester, const Size(320, 640));
      await tester.pumpWidget(wrap(Scaffold(
        body: ShellPage(
          title: 'A rather long page title that will not fit',
          actions: [
            TextButton(onPressed: () {}, child: const Text('Export')),
            TextButton(onPressed: () {}, child: const Text('Delete')),
          ],
          children: const [Text('body')],
        ),
      )));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('ResponsiveColumns', () {
    testWidgets('stacks when narrow and spreads when wide', (tester) async {
      Widget subject() => wrap(const Scaffold(
            body: ResponsiveColumns(
              minColumnWidth: 300,
              children: [
                SizedBox(height: 40, child: Text('A')),
                SizedBox(height: 40, child: Text('B')),
              ],
            ),
          ));

      useSize(tester, const Size(400, 800));
      await tester.pumpWidget(subject());
      await tester.pumpAndSettle();
      final narrowA = tester.getTopLeft(find.text('A'));
      final narrowB = tester.getTopLeft(find.text('B'));
      expect(narrowB.dy, greaterThan(narrowA.dy), reason: 'should stack');
      expect(tester.takeException(), isNull);

      useSize(tester, const Size(1200, 800));
      await tester.pumpWidget(subject());
      await tester.pumpAndSettle();
      final wideA = tester.getTopLeft(find.text('A'));
      final wideB = tester.getTopLeft(find.text('B'));
      expect(wideB.dx, greaterThan(wideA.dx), reason: 'should sit side by side');
      expect(wideB.dy, equals(wideA.dy));
    });

    testWidgets('an empty child list renders nothing rather than throwing',
        (tester) async {
      await tester.pumpWidget(wrap(const Scaffold(
        body: ResponsiveColumns(children: []),
      )));
      expect(tester.takeException(), isNull);
    });
  });

  group('components', () {
    testWidgets('SectionCard renders its title uppercased with a description',
        (tester) async {
      await tester.pumpWidget(wrap(const Scaffold(
        body: SectionCard(
          title: 'Candidate',
          description: 'How this session is filed',
          child: Text('BODY'),
        ),
      )));
      expect(find.text('CANDIDATE'), findsOneWidget);
      expect(find.text('How this session is filed'), findsOneWidget);
      expect(find.text('BODY'), findsOneWidget);
    });

    testWidgets('StatTile keeps its qualifier attached to the figure',
        (tester) async {
      await tester.pumpWidget(wrap(const Scaffold(
        body: StatTile(
          label: 'Verified',
          value: '4 of 5',
          qualifier: 'one check could not be measured',
        ),
      )));
      // The caveat must be on the same surface as the number — a caveat
      // rendered elsewhere is a caveat a reader can miss.
      expect(find.text('4 of 5'), findsOneWidget);
      expect(find.text('one check could not be measured'), findsOneWidget);
    });

    testWidgets('figures use tabular numerals so columns align',
        (tester) async {
      await tester.pumpWidget(wrap(const Scaffold(
        body: KeyValueRow(label: 'Similarity', value: '96.4'),
      )));

      final value = tester.widget<Text>(find.text('96.4'));
      final features = value.style?.fontFeatures ?? const [];
      expect(
        features.map((f) => f.feature),
        contains('tnum'),
        reason: 'a column of figures that does not align is the single '
            'clearest tell of a styled form pretending to be a data tool',
      );
    });

    testWidgets('ProportionBar always carries its number, not just a length',
        (tester) async {
      await tester.pumpWidget(wrap(const Scaffold(
        body: ProportionBar(fraction: 0.42, label: '42%'),
      )));
      expect(find.text('42%'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
    });

    testWidgets('ProportionBar clamps a nonsense fraction instead of drawing '
        'past its track', (tester) async {
      await tester.pumpWidget(wrap(const Scaffold(
        body: Column(children: [
          ProportionBar(fraction: 4.2, label: 'over'),
          ProportionBar(fraction: -1, label: 'under'),
          ProportionBar(fraction: double.nan, label: 'nan'),
        ]),
      )));
      await tester.pumpAndSettle();

      final bars = tester
          .widgetList<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator))
          .toList();
      expect(bars[0].value, 1.0);
      expect(bars[1].value, 0.0);
      expect(bars[2].value, 0.0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('InlineNotice stays on screen rather than auto-dismissing',
        (tester) async {
      await tester.pumpWidget(wrap(const Scaffold(
        body: InlineNotice(
          message: 'Synthetic data only',
          tone: NoticeTone.caution,
        ),
      )));
      await tester.pump(const Duration(seconds: 10));
      expect(find.text('Synthetic data only'), findsOneWidget);
    });

    testWidgets('every component renders in dark theme', (tester) async {
      useSize(tester, const Size(1000, 900));
      await tester.pumpWidget(wrap(
        Scaffold(
          body: ListView(
            children: [
              const SectionCard(title: 'A', child: Text('x')),
              const SectionCard(
                title: 'Fault',
                tone: SectionTone.fault,
                child: Text('x'),
              ),
              const StatTile(label: 'L', value: '1.0'),
              const KeyValueRow(label: 'K', value: 'V'),
              const InlineNotice(message: 'note'),
              const ProportionBar(fraction: 0.5, label: '50%'),
              NavTile(
                icon: Icons.history,
                title: 'T',
                subtitle: 'S',
                onTap: () {},
              ),
            ],
          ),
        ),
        theme: AppTheme.dark,
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('Breakpoints', () {
    testWidgets('classify the window, not the device', (tester) async {
      late bool compact;
      late bool expanded;

      Widget probe() => wrap(Builder(builder: (context) {
            compact = Breakpoints.isCompact(context);
            expanded = Breakpoints.isExpanded(context);
            return const SizedBox();
          }));

      useSize(tester, const Size(500, 800));
      await tester.pumpWidget(probe());
      expect(compact, isTrue);
      expect(expanded, isFalse);

      useSize(tester, const Size(1400, 800));
      await tester.pumpWidget(probe());
      await tester.pump();
      expect(compact, isFalse);
      expect(expanded, isTrue);
    });
  });
}
