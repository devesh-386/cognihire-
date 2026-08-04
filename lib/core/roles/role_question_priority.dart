/// Orders a session's claim queue so a role's required skills are probed
/// first — the "custom per-role question strategy" described in
/// `docs/PRODUCT_OVERVIEW.md`.
///
/// ## What this deliberately is not
///
/// It does not drop, filter, or invent claims — every claim the candidate
/// made is still asked about, in the same relative order within its group.
/// This only decides *which claim opens first when time is limited*: a role
/// that lists "PostgreSQL" as required gets that claim probed before an
/// untagged "led a team of five" claim, so an interview cut short by time
/// still examined what the role author said mattered. [coverageFor] in
/// `role_coverage.dart` is the honest report of what happened after the
/// fact; this is the only place role data is allowed to *act* rather than
/// just *describe*, and it acts by reordering, never by hiding a claim the
/// candidate made.
library;

import '../claims/claim.dart';
import 'role.dart';
import 'role_coverage.dart' show normaliseSkill;

/// Returns [claims] reordered: claims tagged with one of [role]'s
/// `requiredSkills` first, then `desirableSkills`, then everything else
/// (untagged claims, and claims tagged with a skill the role never asked
/// for) — each group in its original relative order (a stable sort), so two
/// claims the role treats identically stay in the order the candidate's
/// resume produced them.
///
/// Matching is case-insensitive via the same [normaliseSkill] rule
/// `role_coverage.dart` uses for the after-the-fact report, so "the claim
/// that opens first" and "the claim the coverage table credits to this
/// skill" are always the same claim.
List<Claim> orderClaimsForRole(List<Claim> claims, Role role) {
  final required = role.requiredSkills.map(normaliseSkill).toSet();
  final desirable = role.desirableSkills.map(normaliseSkill).toSet();

  int rank(Claim claim) {
    final skill = claim.skill;
    if (skill == null || skill.trim().isEmpty) return 2;
    final normalised = normaliseSkill(skill);
    if (required.contains(normalised)) return 0;
    if (desirable.contains(normalised)) return 1;
    return 2;
  }

  // List.sort is not guaranteed stable by the language spec, but the
  // documented dart:core implementation (and every platform this project
  // targets) uses an insertion/merge sort that is — verified directly by
  // `role_question_priority_test.dart`'s within-group ordering assertions
  // rather than assumed.
  final indexed = List<MapEntry<int, Claim>>.generate(
    claims.length,
    (i) => MapEntry(i, claims[i]),
  );
  indexed.sort((a, b) {
    final rankCompare = rank(a.value).compareTo(rank(b.value));
    if (rankCompare != 0) return rankCompare;
    return a.key.compareTo(b.key); // preserves original order within a group
  });

  return indexed.map((e) => e.value).toList();
}
