/// Proves the newly wired features are reachable in the running app.
///
/// This file exists because three finished, fully-tested features sat orphaned:
/// nothing in `lib/` imported them, so every unit test passed while the app
/// showed none of it. Unit tests prove a thing works; only these prove a user
/// can get to it. When wiring a new screen, add its route here.
library;

import 'package:cognihire/core/claims/claim.dart';
import 'package:cognihire/core/claims/claim_audit.dart';
import 'package:cognihire/core/design/app_theme.dart';
import 'package:cognihire/features/audit/claim_audit_screen.dart';
import 'package:cognihire/features/reviewer/model_decision_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ClaimAudit _audit() {
  final start = DateTime.utc(2026, 7, 30, 9);
  return const ClaimAuditBuilder().build(
    claims: const [
      Claim(id: 'c1', text: 'Built a distributed cache', source: 'Resume'),
    ],
    evidenceByClaimId: {
      'c1': [
        ClaimEvidence(
          observation: 'Asked about it. Candidate responded.',
          kind: EvidenceKind.probeResponse,
          at: start.add(const Duration(minutes: 1)),
        ),
      ],
    },
    reviewerAssessments: const {'c1': ClaimStatus.substantiated},
    identityAttempts: const [],
    sessionStart: start,
    sessionEnd: start.add(const Duration(minutes: 5)),
    sessionEventsJsonl: '',
  );
}

void main() {
  testWidgets('the model decision screen is reachable from the claim audit',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      home: ClaimAuditScreen(audit: _audit()),
    ));
    await tester.pumpAndSettle();

    final entry = find.widgetWithText(TextButton, 'Model view');
    expect(entry, findsOneWidget,
        reason: 'without an entry point the screen is dead code');

    await tester.tap(entry);
    await tester.pumpAndSettle();

    expect(find.byType(ModelDecisionScreen), findsOneWidget);
    // And it renders a real decision built from this audit, not a placeholder.
    expect(find.textContaining('Model estimate:'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
