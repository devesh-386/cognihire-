/// Aggregates across every stored session — the numbers the dashboard reports.
///
/// ## Why this is a separate, Flutter-free layer
///
/// The dashboard mockup this serves is a wall of figures: totals, a funnel, a
/// per-skill breakdown, an activity feed. The tempting way to build that is to
/// compute each number inline in the widget that shows it. Two things go wrong
/// when you do. The arithmetic becomes untestable, so nobody ever checks that
/// "claims examined" and "claims not examined" sum to the total. And the
/// definition of each figure ends up implicit in a `.where()` clause buried in a
/// build method, which is how a metric quietly starts meaning something other
/// than its label.
///
/// So every figure the dashboard shows is computed here, from stored audits, in
/// plain Dart, with the definition written next to it.
///
/// ## What is deliberately absent
///
/// There is no overall score, no per-candidate ranking, no "hiring score", and
/// no quality index. The mockup had all four. They are not omitted because they
/// were hard — a weighted sum is trivial — but because a composite number is
/// precisely the artefact this product argues against, and putting one on the
/// front page would undo the rest of the app. Everything here is a **count, or a
/// ratio of two counts that are both stated**.
library;

import '../claims/claim.dart';
import '../claims/claim_audit.dart';
import '../persistence/audit_store.dart';

/// One stored session, paired with its loaded audit.
class SessionRecord {
  const SessionRecord({required this.summary, required this.audit});

  final SessionSummary summary;
  final ClaimAudit audit;

  String get id => summary.id;
  String get label => summary.label;
}

/// A stage in the provenance funnel: how many claims got this far, and what
/// getting this far actually required.
class FunnelCount {
  const FunnelCount({
    required this.label,
    required this.count,
    required this.definition,
  });

  final String label;
  final int count;

  /// The predicate, in words. Shown to the reader, so a bar can never come to
  /// mean something other than what was measured.
  final String definition;
}

/// Coverage of one skill tag across every session.
class SkillCoverage {
  const SkillCoverage({
    required this.skill,
    required this.claims,
    required this.examined,
    required this.substantiated,
    required this.evidenceItems,
  });

  final String skill;
  final int claims;
  final int examined;
  final int substantiated;
  final int evidenceItems;

  /// Share of this skill's claims that were examined at all. Null when there are
  /// no claims for the skill, because a ratio with a zero denominator is not
  /// zero — it does not exist.
  double? get examinedFraction => claims == 0 ? null : examined / claims;

  double? get substantiatedFraction =>
      examined == 0 ? null : substantiated / examined;
}

/// One thing that happened, for the activity feed.
class ActivityItem {
  const ActivityItem({
    required this.at,
    required this.title,
    required this.detail,
    required this.sessionId,
    this.isFault = false,
  });

  final DateTime at;
  final String title;
  final String detail;

  /// Empty when the item is not attached to a readable session (a corrupt
  /// record, for instance), so a caller knows there is nothing to open.
  final String sessionId;

  final bool isFault;
}

/// Everything the dashboard reports, computed once from the stored sessions.
class WorkspaceStats {
  const WorkspaceStats({
    required this.sessions,
    required this.unreadableSessions,
    required this.candidates,
    required this.claimsTotal,
    required this.claimsByStatus,
    required this.claimsProbed,
    required this.claimsWithProcessSignal,
    required this.claimsReviewerAssessed,
    required this.evidenceItems,
    required this.identityAttempts,
    required this.identityMeasured,
    required this.identityVerified,
    required this.totalSessionTime,
    required this.skills,
    required this.activity,
    required this.mostRecent,
  });

  /// An empty workspace. Distinguishable from a populated one by
  /// [sessions] == 0, which every consumer must check before showing a ratio.
  factory WorkspaceStats.empty() => const WorkspaceStats(
        sessions: 0,
        unreadableSessions: 0,
        candidates: 0,
        claimsTotal: 0,
        claimsByStatus: {},
        claimsProbed: 0,
        claimsWithProcessSignal: 0,
        claimsReviewerAssessed: 0,
        evidenceItems: 0,
        identityAttempts: 0,
        identityMeasured: 0,
        identityVerified: 0,
        totalSessionTime: Duration.zero,
        skills: [],
        activity: [],
        mostRecent: null,
      );

  factory WorkspaceStats.from(
    List<SessionRecord> records, {
    List<UnreadableSession> unreadable = const [],
  }) {
    final byStatus = <ClaimStatus, int>{
      for (final s in ClaimStatus.values) s: 0,
    };

    var claimsTotal = 0;
    var probed = 0;
    var withProcess = 0;
    var assessed = 0;
    var evidence = 0;
    var attempts = 0;
    var measured = 0;
    var verified = 0;
    var time = Duration.zero;

    final skillClaims = <String, List<ClaimFinding>>{};
    final activity = <ActivityItem>[];

    for (final record in records) {
      final audit = record.audit;
      time += audit.sessionEnd.difference(audit.sessionStart);
      attempts += audit.identityAttempts.length;
      measured += audit.identityChecksPerformed;
      verified += audit.identityChecksVerified;

      for (final finding in audit.findings) {
        claimsTotal++;
        byStatus[finding.status] = (byStatus[finding.status] ?? 0) + 1;
        evidence += finding.evidence.length;

        if (finding.evidence
            .any((e) => e.kind == EvidenceKind.probeResponse)) {
          probed++;
        }
        if (finding.evidence
            .any((e) => e.kind == EvidenceKind.processSignal)) {
          withProcess++;
        }
        // A reviewer only ever moves a claim *off* the default. Substantiated
        // and contradicted are both human calls; "not demonstrated" is the
        // builder's default for a probed claim nobody has ruled on, so counting
        // it here would inflate reviewer activity with inaction.
        if (finding.status == ClaimStatus.substantiated ||
            finding.status == ClaimStatus.contradicted) {
          assessed++;
        }

        final skill = finding.claim.skill;
        if (skill != null && skill.trim().isNotEmpty) {
          skillClaims.putIfAbsent(skill.trim(), () => []).add(finding);
        }
      }

      activity.add(ActivityItem(
        at: audit.sessionEnd,
        title: record.label,
        detail: audit.summary,
        sessionId: record.id,
      ));
    }

    for (final bad in unreadable) {
      activity.add(ActivityItem(
        // No readable timestamp exists for a record that would not parse, so it
        // is filed at epoch and sorts to the bottom rather than being given an
        // invented "now".
        at: DateTime.fromMillisecondsSinceEpoch(0),
        title: 'Unreadable session ${bad.id}',
        detail: bad.problem,
        sessionId: '',
        isFault: true,
      ));
    }

    activity.sort((a, b) => b.at.compareTo(a.at));

    final skills = skillClaims.entries.map((entry) {
      final findings = entry.value;
      return SkillCoverage(
        skill: entry.key,
        claims: findings.length,
        examined: findings
            .where((f) => f.status != ClaimStatus.notExamined)
            .length,
        substantiated: findings
            .where((f) => f.status == ClaimStatus.substantiated)
            .length,
        evidenceItems:
            findings.fold(0, (sum, f) => sum + f.evidence.length),
      );
    }).toList()
      // Most-covered first: the skills with the most claims behind them are the
      // ones a reviewer has the most to read about.
      ..sort((a, b) {
        final byClaims = b.claims.compareTo(a.claims);
        return byClaims != 0 ? byClaims : a.skill.compareTo(b.skill);
      });

    final sorted = [...records]
      ..sort((a, b) => b.audit.sessionEnd.compareTo(a.audit.sessionEnd));

    return WorkspaceStats(
      sessions: records.length,
      unreadableSessions: unreadable.length,
      candidates: records.map((r) => r.label.trim().toLowerCase()).toSet().length,
      claimsTotal: claimsTotal,
      claimsByStatus: Map.unmodifiable(byStatus),
      claimsProbed: probed,
      claimsWithProcessSignal: withProcess,
      claimsReviewerAssessed: assessed,
      evidenceItems: evidence,
      identityAttempts: attempts,
      identityMeasured: measured,
      identityVerified: verified,
      totalSessionTime: time,
      skills: List.unmodifiable(skills),
      activity: List.unmodifiable(activity),
      mostRecent: sorted.isEmpty ? null : sorted.first,
    );
  }

  final int sessions;
  final int unreadableSessions;

  /// Distinct session labels, case-insensitively. This is an approximation and
  /// is labelled as one wherever it is shown: the label is free text the
  /// operator typed, so two spellings of one person count twice. The product has
  /// no candidate identity record to do better with, and inventing one by
  /// fuzzy-matching names would be worse than the honest approximation.
  final int candidates;

  final int claimsTotal;
  final Map<ClaimStatus, int> claimsByStatus;

  /// Claims with at least one recorded probe-and-response.
  final int claimsProbed;

  /// Claims with at least one recorded process signal (timing, revision, bulk
  /// insertion).
  final int claimsWithProcessSignal;

  /// Claims a human reviewer actually ruled on, either way.
  final int claimsReviewerAssessed;

  final int evidenceItems;
  final int identityAttempts;
  final int identityMeasured;
  final int identityVerified;
  final Duration totalSessionTime;
  final List<SkillCoverage> skills;
  final List<ActivityItem> activity;
  final SessionRecord? mostRecent;

  bool get isEmpty => sessions == 0 && unreadableSessions == 0;

  int statusCount(ClaimStatus status) => claimsByStatus[status] ?? 0;

  int get claimsExamined =>
      claimsTotal - statusCount(ClaimStatus.notExamined);

  /// Share of identity attempts that measured something. Null when nothing was
  /// attempted — see [ClaimAudit.identityCoverage] for why this is not 1.0.
  double? get identityCoverage =>
      identityAttempts == 0 ? null : identityMeasured / identityAttempts;

  /// Share of *measured* checks that matched. Null when nothing was measured.
  /// The denominator is measured checks, not attempts: dividing by attempts
  /// would let a session that could not see conflate "did not match" with "could
  /// not look".
  double? get identityVerifiedFraction =>
      identityMeasured == 0 ? null : identityVerified / identityMeasured;

  double? get examinedFraction =>
      claimsTotal == 0 ? null : claimsExamined / claimsTotal;

  /// The funnel, top stage first. Each stage is a subset of the one above it, so
  /// the counts are monotonically non-increasing by construction.
  List<FunnelCount> get funnel => [
        FunnelCount(
          label: 'Claims ingested',
          count: claimsTotal,
          definition: 'Every claim the candidate confirmed from their own '
              'resume, across all stored sessions.',
        ),
        FunnelCount(
          label: 'Probed in a session',
          count: claimsProbed,
          definition: 'A question was asked about the claim and the candidate '
              'answered. Recorded as probe-response evidence.',
        ),
        FunnelCount(
          label: 'Process signal captured',
          count: claimsWithProcessSignal,
          definition: 'How the answer was produced was also measured — typing '
              'timing, revision ratio, or bulk insertion.',
        ),
        FunnelCount(
          label: 'Ruled on by a reviewer',
          count: claimsReviewerAssessed,
          definition: 'A human marked the claim substantiated or contradicted. '
              'Claims left at the default are not counted here.',
        ),
      ];
}
