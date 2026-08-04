/// Matches a [Role]'s skill list against what a session actually examined.
///
/// Pure and deterministic. The whole decision layer is the switch in
/// [coverageFor] and it fits on one screen, which is the point: a reviewer
/// challenged on "why does it say that?" should be able to read the rule rather
/// than be told a model decided.
library;

import '../claims/claim.dart';
import '../claims/claim_audit.dart';
import 'role.dart';

/// Skill tags are author-typed on both sides — a role says "PostgreSQL", a
/// resume says "postgresql" — so matching folds case and trims. It does not do
/// anything cleverer: no stemming, no synonym list, no fuzzy distance. A
/// near-match silently counted as a match is a false claim of coverage, and the
/// honest failure mode is to report the gap and let the author fix their spelling.
String normaliseSkill(String skill) => skill.trim().toLowerCase();

/// A coverage report for one session against one role.
class RoleCoverage {
  const RoleCoverage({
    required this.role,
    required this.rows,
    required this.untaggedClaims,
    required this.claimsOutsideRole,
  });

  final Role role;
  final List<SkillCoverageRow> rows;

  /// Claims with no skill tag at all. Counted and reported rather than dropped:
  /// they are real claims that this report cannot speak to, and hiding them
  /// would make the coverage look more complete than it is.
  final int untaggedClaims;

  /// Skill tags present in the session that the role never asked for.
  final List<String> claimsOutsideRole;

  List<SkillCoverageRow> get requiredRows =>
      rows.where((r) => r.required_).toList();

  /// Required skills with no claim behind them at all.
  List<SkillCoverageRow> get missingRequired => requiredRows
      .where((r) => r.state == SkillEvidenceState.noClaim)
      .toList();

  /// Required skills claimed but never tested. Distinct from missing, and the
  /// more actionable of the two: this is what another session could fix.
  List<SkillCoverageRow> get untestedRequired => requiredRows
      .where((r) => r.state == SkillEvidenceState.claimedNotExamined)
      .toList();

  int get requiredSubstantiated => requiredRows
      .where((r) => r.state == SkillEvidenceState.substantiatedClaim)
      .length;

  /// Share of required skills backed by a substantiated claim. Null when the
  /// role lists no required skills — there is no ratio to report, and returning
  /// 1.0 would announce complete coverage of an empty list.
  double? get requiredSubstantiatedFraction =>
      requiredRows.isEmpty ? null : requiredSubstantiated / requiredRows.length;

  /// The one line to show above the table. States counts, recommends nothing.
  String get summary {
    if (requiredRows.isEmpty) {
      return 'This role lists no required skills, so there is nothing to check '
          'against.';
    }
    return '$requiredSubstantiated of ${requiredRows.length} required skills '
        'have a substantiated claim · ${untestedRequired.length} claimed but '
        'not tested · ${missingRequired.length} not claimed';
  }
}

RoleCoverage coverageFor(Role role, ClaimAudit audit) {
  // Group the session's findings by normalised skill tag once, so the per-skill
  // lookup below is not quadratic in claims × skills.
  final bySkill = <String, List<ClaimFinding>>{};
  var untagged = 0;

  for (final finding in audit.findings) {
    final skill = finding.claim.skill;
    if (skill == null || skill.trim().isEmpty) {
      untagged++;
      continue;
    }
    bySkill.putIfAbsent(normaliseSkill(skill), () => []).add(finding);
  }

  SkillCoverageRow row(String skill, {required bool isRequired}) {
    final findings = bySkill[normaliseSkill(skill)] ?? const <ClaimFinding>[];

    // Best-evidenced claim wins the row. A candidate with two claims for one
    // skill, one substantiated, should not be reported as untested because the
    // other claim happened to be listed second.
    final state = findings.isEmpty
        ? SkillEvidenceState.noClaim
        : findings.any((f) => f.status == ClaimStatus.substantiated)
            ? SkillEvidenceState.substantiatedClaim
            : findings.any((f) => f.status != ClaimStatus.notExamined)
                ? SkillEvidenceState.examinedClaim
                : SkillEvidenceState.claimedNotExamined;

    return SkillCoverageRow(
      skill: skill,
      required_: isRequired,
      state: state,
      claimCount: findings.length,
    );
  }

  final rows = <SkillCoverageRow>[
    for (final skill in role.requiredSkills) row(skill, isRequired: true),
    for (final skill in role.desirableSkills) row(skill, isRequired: false),
  ];

  final asked = role.allSkills.map(normaliseSkill).toSet();
  final extra = bySkill.keys.where((k) => !asked.contains(k)).toList()..sort();

  return RoleCoverage(
    role: role,
    rows: rows,
    untaggedClaims: untagged,
    // Reported with the session's own spelling rather than the normalised key,
    // so an author fixing a mismatch sees what they actually need to type.
    claimsOutsideRole: [
      for (final key in extra)
        bySkill[key]!.first.claim.skill!.trim(),
    ],
  );
}
