import '../verification/verification_result.dart';
import 'claim.dart';

/// The audit for a single claim: status plus the evidence behind it.
class ClaimFinding {
  const ClaimFinding({
    required this.claim,
    required this.status,
    required this.evidence,
  });

  final Claim claim;
  final ClaimStatus status;
  final List<ClaimEvidence> evidence;
}

/// What is delivered to a human reviewer at the end of a session.
///
/// ## What this is not
///
/// Not a score, not a ranking, not a recommendation, and explicitly not a
/// hire/no-hire signal. Those are the outputs that made AI hiring tools a
/// regulatory problem: NYC Local Law 144 requires an independent bias audit of
/// any tool making an employment decision, and the EU AI Act classifies
/// candidate evaluation as high-risk requiring effective human oversight. A
/// per-claim evidence trail is close to the shape regulators are asking for; a
/// single opaque number is the expensive thing to defend.
///
/// So the audit answers one question per claim — "did they show this?" — and
/// leaves the decision entirely with the reviewer.
class ClaimAudit {
  const ClaimAudit({
    required this.findings,
    required this.sessionStart,
    required this.sessionEnd,
    required this.identityAttempts,
    this.sessionEventsJsonl = '',
  });

  final List<ClaimFinding> findings;
  final DateTime sessionStart;
  final DateTime sessionEnd;

  /// The session's tamper-evident event log, serialised as JSONL. Empty when no
  /// events were recorded. Carried on the audit so the conclusion and the
  /// provenance behind it are stored and loaded as one unit; a
  /// `SessionEventLog.fromJsonl` reconstructs and re-verifies it.
  final String sessionEventsJsonl;

  /// Every identity verification attempt in the session, including the ones
  /// that could not be performed.
  final List<VerificationResult> identityAttempts;

  List<ClaimFinding> byStatus(ClaimStatus status) =>
      findings.where((f) => f.status == status).toList();

  /// Attempts where the system genuinely measured something.
  int get identityChecksPerformed =>
      identityAttempts.where((r) => r.didMeasure).length;

  /// Attempts that could not be performed at all.
  int get identityChecksUnmeasured =>
      identityAttempts.where((r) => !r.didMeasure).length;

  int get identityChecksVerified =>
      identityAttempts.where((r) => r.isVerified).length;

  /// Proportion of attempts that actually measured, or null when nothing was
  /// attempted. Null rather than 1.0: a session with no checks has not achieved
  /// perfect coverage, it has achieved none.
  double? get identityCoverage {
    if (identityAttempts.isEmpty) return null;
    return identityChecksPerformed / identityAttempts.length;
  }

  /// Whether this session's provenance evidence is strong enough to rely on.
  ///
  /// Deliberately conservative: if the system spent much of the session unable
  /// to see, it says so rather than presenting sparse evidence as solid. A
  /// reviewer reading "verified" deserves to know how often that was checked.
  ProvenanceQuality get provenanceQuality {
    final coverage = identityCoverage;
    if (coverage == null) return ProvenanceQuality.none;
    if (identityChecksPerformed == 0) return ProvenanceQuality.none;
    if (coverage < 0.5) return ProvenanceQuality.sparse;
    if (identityChecksVerified < identityChecksPerformed) {
      return ProvenanceQuality.disputed;
    }
    return ProvenanceQuality.solid;
  }

  /// The one line a reviewer reads first. States what is known and what is not,
  /// and recommends nothing.
  String get summary {
    final examined = findings.where((f) => f.status != ClaimStatus.notExamined);
    final unexamined = byStatus(ClaimStatus.notExamined);

    final parts = <String>[
      '${examined.length} of ${findings.length} claims examined',
      if (unexamined.isNotEmpty) '${unexamined.length} not tested',
      switch (provenanceQuality) {
        ProvenanceQuality.solid =>
          'identity verified across $identityChecksPerformed checks',
        ProvenanceQuality.disputed =>
          'identity disputed in ${identityChecksPerformed - identityChecksVerified} '
              'of $identityChecksPerformed checks',
        ProvenanceQuality.sparse =>
          'identity coverage incomplete ($identityChecksPerformed of '
              '${identityAttempts.length} attempts succeeded)',
        ProvenanceQuality.none => 'identity could not be verified',
      },
    ];

    return parts.join(' · ');
  }
}

enum ProvenanceQuality {
  /// Checks ran and all matched.
  solid,

  /// Checks ran; at least one did not match.
  disputed,

  /// More than half the attempts could not be performed.
  sparse,

  /// Nothing was successfully measured.
  none,
}

/// Assembles the audit from what happened in the session.
///
/// Pure and deterministic: given the same session events it always produces the
/// same audit. No model decides a claim's status — the rules below are the
/// whole decision layer, and they are readable in one screen.
class ClaimAuditBuilder {
  const ClaimAuditBuilder();

  ClaimAudit build({
    required List<Claim> claims,
    required Map<String, List<ClaimEvidence>> evidenceByClaimId,
    required Map<String, ClaimStatus> reviewerAssessments,
    required List<VerificationResult> identityAttempts,
    required DateTime sessionStart,
    required DateTime sessionEnd,
    String sessionEventsJsonl = '',
  }) {
    final findings = <ClaimFinding>[];

    for (final claim in claims) {
      final evidence = evidenceByClaimId[claim.id] ?? const <ClaimEvidence>[];

      // A claim with no evidence was not examined. It is never assumed either
      // way — silence is reported as silence.
      final status = evidence.isEmpty
          ? ClaimStatus.notExamined
          : reviewerAssessments[claim.id] ?? ClaimStatus.notDemonstrated;

      findings.add(ClaimFinding(
        claim: claim,
        status: status,
        evidence: List.unmodifiable(evidence),
      ));
    }

    return ClaimAudit(
      findings: List.unmodifiable(findings),
      sessionStart: sessionStart,
      sessionEnd: sessionEnd,
      identityAttempts: List.unmodifiable(identityAttempts),
      sessionEventsJsonl: sessionEventsJsonl,
    );
  }
}
