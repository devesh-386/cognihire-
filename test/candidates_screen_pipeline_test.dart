import 'package:cognihire/core/candidates/candidate.dart';
import 'package:cognihire/core/candidates/candidate_store.dart';
import 'package:cognihire/core/persistence/audit_store.dart';
import 'package:cognihire/features/candidates/candidates_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The "Recruiting pipeline" section CandidatesScreen shows above its
/// existing local-session list — real candidates.candidate rows, distinct
/// from the free-text session labels that section has always meant.
void main() {
  Widget screenFor(CandidateStore store) => MaterialApp(
        home: Scaffold(
          body: CandidatesScreen(
            store: InMemoryAuditStore(),
            candidateStore: store,
          ),
        ),
      );

  testWidgets('with no pipeline candidates, says so rather than showing nothing',
      (tester) async {
    await tester.pumpWidget(screenFor(const InMemoryCandidateStore()));
    await tester.pumpAndSettle();

    expect(find.text('RECRUITING PIPELINE'), findsOneWidget);
    expect(find.textContaining('Nobody has applied'), findsOneWidget);
  });

  testWidgets('shows a pipeline candidate with their role and status', (tester) async {
    final store = InMemoryCandidateStore([
      Candidate(
        id: 'cand-1',
        name: 'Priya Sharma',
        email: 'priya@example.com',
        createdAt: DateTime(2026, 8, 1),
        roleId: 'role-1',
        roleTitle: 'Backend Engineer',
        intakeId: 'intake-1',
        intakeName: 'August 2026 Intake',
        processingStatus: 'READY_FOR_INTERVIEW',
      ),
    ]);

    await tester.pumpWidget(screenFor(store));
    await tester.pumpAndSettle();

    expect(find.text('Priya Sharma'), findsOneWidget);
    expect(find.textContaining('Backend Engineer'), findsOneWidget);
    expect(find.text('August 2026 Intake'), findsOneWidget);
    expect(find.text('ready for interview'), findsOneWidget);
  });

  testWidgets('candidates with no intake are grouped as unassigned', (tester) async {
    final store = InMemoryCandidateStore([
      Candidate(
        id: 'cand-2',
        name: 'Legacy Candidate',
        email: 'legacy@example.com',
        createdAt: DateTime(2026, 1, 1),
      ),
    ]);

    await tester.pumpWidget(screenFor(store));
    await tester.pumpAndSettle();

    expect(find.textContaining('Unassigned'), findsOneWidget);
    expect(find.text('Legacy Candidate'), findsOneWidget);
  });

  testWidgets('a pipeline read failure is shown, not swallowed', (tester) async {
    await tester.pumpWidget(screenFor(_FailingCandidateStore()));
    await tester.pumpAndSettle();

    expect(find.textContaining('could not be read'), findsOneWidget);
  });
}

class _FailingCandidateStore implements CandidateStore {
  @override
  Future<List<Candidate>> listCandidates() async {
    throw StateError('network unavailable');
  }
}
