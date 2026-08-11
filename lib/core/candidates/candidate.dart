/// A candidate in the real recruiting pipeline (Supabase `candidates`
/// table) — distinct from `CandidatesScreen`'s existing local session
/// groups, which are free-text labels typed during an in-person session
/// run through this app directly. Both concepts are real; they are not the
/// same thing, and this app is careful not to conflate them (see
/// candidates_screen.dart's own doc comment on why a "candidate" here has
/// always meant a label, not an identity record).
///
/// This one *is* an identity record, in the ordinary sense: a row created
/// when someone applied through a role's intake, with a name and email they
/// supplied and an organization/role/intake ownership chain established at
/// creation (never inferred later — see infra/migrations/0008_intakes.sql).
library;

class Candidate {
  const Candidate({
    required this.id,
    required this.name,
    required this.email,
    required this.createdAt,
    this.roleId,
    this.roleTitle,
    this.intakeId,
    this.intakeName,
    this.processingStatus,
  });

  final String id;
  final String name;
  final String email;
  final DateTime createdAt;

  final String? roleId;
  final String? roleTitle;

  /// Null for candidates who predate intakes (see intake_id's own comment
  /// in the migration) — shown as "Unassigned" rather than hidden.
  final String? intakeId;
  final String? intakeName;

  /// From `candidate_ai_profile.processing_status` — null means no AI
  /// profile exists yet at all (resume just uploaded, trigger hasn't fired),
  /// distinct from an explicit "FAILED" or "READY_FOR_INTERVIEW".
  final String? processingStatus;
}
