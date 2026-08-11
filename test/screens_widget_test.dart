/// Widget tests that actually mount the screens.
///
/// The rest of the suite is pure-Dart logic, which is fast and precise but
/// structurally blind to an entire class of failure: a screen that throws the
/// moment it builds. A `setState` callback that returned a Future shipped and
/// crashed the session-history screen on open, with 162 green tests, because
/// nothing in the suite had ever constructed a widget.
///
/// These tests are the floor: every screen builds, renders its empty and
/// populated states, and survives a refresh.
library;

import 'package:cognihire/core/claims/claim.dart';
import 'package:cognihire/core/claims/claim_audit.dart';
import 'package:cognihire/core/design/app_theme.dart';
import 'package:cognihire/core/graph/graph_from_audit.dart';
import 'package:cognihire/core/persistence/audit_store.dart';
import 'package:cognihire/core/verification/verification_result.dart';
import 'package:cognihire/features/audit/claim_audit_screen.dart';
import 'package:cognihire/features/graph/evidence_graph_screen.dart';
import 'package:cognihire/features/sessions/session_history_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ClaimAudit _audit() {
  final start = DateTime.utc(2026, 7, 27, 9);
  return const ClaimAuditBuilder().build(
    claims: const [
      Claim(
        id: 'c1',
        text: 'Built a distributed cache',
        source: 'Resume, page 1',
        skill: 'Redis',
      ),
      Claim(id: 'c2', text: 'Led a CI migration', source: 'Cover letter'),
    ],
    evidenceByClaimId: {
      'c1': [
        ClaimEvidence(
          observation: 'Described consistent hashing when asked.',
          kind: EvidenceKind.probeResponse,
          at: start.add(const Duration(minutes: 6)),
        ),
      ],
    },
    reviewerAssessments: const {'c1': ClaimStatus.substantiated},
    identityAttempts: [
      Verified(similarity: 96.4, at: start.add(const Duration(minutes: 1))),
      Unchecked(
        reason: UncheckedReason.noFaceInFrame,
        at: start.add(const Duration(minutes: 15)),
      ),
    ],
    sessionStart: start,
    sessionEnd: start.add(const Duration(minutes: 30)),
  );
}

Widget _wrap(Widget child, {Brightness brightness = Brightness.light}) =>
    MaterialApp(
      theme: brightness == Brightness.light ? AppTheme.light : AppTheme.dark,
      home: child,
    );

Widget _history(AuditStore store) => _wrap(
      SessionHistoryScreen(
        store: store,
        storageLocation: '/tmp/cognihire',
        storageIsDurable: true,
      ),
    );

void main() {
  group('SessionHistoryScreen', () {
    // The regression this file exists for.
    testWidgets('opens without throwing when the store is empty',
        (tester) async {
      await tester.pumpWidget(_history(InMemoryAuditStore()));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('No saved sessions yet'), findsOneWidget);
    });

    testWidgets('lists a saved session', (tester) async {
      final store = InMemoryAuditStore();
      await store.saveAudit(_audit(), label: 'Alice Nguyen');

      await tester.pumpWidget(_history(store));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Alice Nguyen'), findsOneWidget);
    });

    testWidgets('the refresh button does not throw', (tester) async {
      final store = InMemoryAuditStore();
      await store.saveAudit(_audit(), label: 'Alice');

      await tester.pumpWidget(_history(store));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Refresh'));
      await tester.pumpAndSettle();

      // Directly covers the setState-returned-a-Future crash.
      expect(tester.takeException(), isNull);
      expect(find.text('Alice'), findsOneWidget);
    });

    testWidgets('opening a stored audit navigates without throwing',
        (tester) async {
      final store = InMemoryAuditStore();
      await store.saveAudit(_audit(), label: 'Alice');

      await tester.pumpWidget(_history(store));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Alice'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Claim audit'), findsOneWidget);
    });

    testWidgets('renders in dark theme too', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: SessionHistoryScreen(
            store: InMemoryAuditStore(),
            storageLocation: '/tmp/cognihire',
            storageIsDurable: true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });
  });

  group('ClaimAuditScreen', () {
    testWidgets('builds and shows every claim', (tester) async {
      await tester.pumpWidget(
        _wrap(ClaimAuditScreen(audit: _audit(), label: 'Alice')),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.textContaining('distributed cache'), findsWidgets);
      expect(find.textContaining('CI migration'), findsWidgets);
    });

    testWidgets('states plainly that it makes no recommendation',
        (tester) async {
      await tester.pumpWidget(
        _wrap(ClaimAuditScreen(audit: _audit(), label: 'Alice')),
      );
      await tester.pumpAndSettle();

      // The notice sits at the end of a lazy ListView, so scroll it into
      // existence rather than asserting against an unbuilt widget.
      final notice = find.textContaining('does not contain a hiring '
          'recommendation');
      await tester.scrollUntilVisible(notice, 300);
      await tester.pumpAndSettle();

      expect(notice, findsOneWidget);
    });

    testWidgets('reports an unexamined claim rather than hiding it',
        (tester) async {
      await tester.pumpWidget(
        _wrap(ClaimAuditScreen(audit: _audit(), label: 'Alice')),
      );
      await tester.pumpAndSettle();

      expect(find.text('Not examined'), findsOneWidget);
    });

    testWidgets('navigates to the evidence graph without throwing',
        (tester) async {
      await tester.pumpWidget(
        _wrap(ClaimAuditScreen(audit: _audit(), label: 'Alice')),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('View evidence graph').first);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Evidence graph'), findsOneWidget);
    });
  });

  group('EvidenceGraphScreen', () {
    testWidgets('builds from a derived graph', (tester) async {
      final graph = graphForClaim(_audit(), 'c1')!;

      await tester.pumpWidget(
        _wrap(EvidenceGraphScreen(graph: graph, claimText: 'Built a cache')),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Evidence graph'), findsOneWidget);
    });

    testWidgets('shows the full edge-type legend', (tester) async {
      final graph = graphForClaim(_audit(), 'c1')!;

      await tester.pumpWidget(
        _wrap(EvidenceGraphScreen(graph: graph)),
      );
      await tester.pumpAndSettle();

      // The closed edge-type enum is what makes a complete legend possible;
      // if a type is ever added without a label this fails.
      expect(find.text('supports'), findsOneWidget);
      expect(find.text('contradicts'), findsOneWidget);
      expect(find.text('derived from'), findsOneWidget);
    });

    testWidgets('tapping a node reveals its relationships', (tester) async {
      final graph = graphForClaim(_audit(), 'c1')!;

      await tester.pumpWidget(
        _wrap(EvidenceGraphScreen(graph: graph)),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('Tap any node'), findsOneWidget);

      await tester.tap(find.text('CLAIM'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.textContaining('Relationships'), findsOneWidget);
    });

    testWidgets('shows no aggregate score anywhere on screen', (tester) async {
      final graph = graphForClaim(_audit(), 'c1')!;

      await tester.pumpWidget(
        _wrap(EvidenceGraphScreen(graph: graph)),
      );
      await tester.pumpAndSettle();

      // The product's core constraint, asserted against what actually renders
      // rather than only against the data model.
      for (final banned in ['Score', 'score', 'Strength', 'Rating', '%']) {
        expect(
          find.textContaining(banned),
          findsNothing,
          reason: '"$banned" must never appear on the graph view',
        );
      }
    });

    testWidgets('renders in dark theme', (tester) async {
      final graph = graphForClaim(_audit(), 'c1')!;

      await tester.pumpWidget(
        _wrap(EvidenceGraphScreen(graph: graph), brightness: Brightness.dark),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });
  });
}
