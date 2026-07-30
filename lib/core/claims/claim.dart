/// Something the candidate asserted about themselves.
///
/// Claims come from the resume or application, not from inference. If we did
/// not read it in their own words, it is not a claim and does not belong here.
class Claim {
  const Claim({
    required this.id,
    required this.text,
    required this.source,
    this.skill,
  });

  final String id;

  /// The assertion, quoted as closely as possible to how the candidate wrote it.
  final String text;

  /// Where it was stated, so a reviewer can go and read the original.
  final String source;

  /// Optional skill tag used to select a relevant task.
  final String? skill;
}

/// The status of a claim after the session.
///
/// There is no numeric score and no ranking. A claim is examined or it is not;
/// if examined, the evidence either supports it, fails to support it, or runs
/// against it. Collapsing that into a percentage would discard exactly the
/// information a human reviewer needs to make the decision themselves.
enum ClaimStatus {
  /// The candidate demonstrated the claim under questioning.
  substantiated(
    'Substantiated',
    'The candidate demonstrated this claim when asked about it.',
  ),

  /// It was probed, and the response did not demonstrate it. This is not an
  /// accusation of dishonesty — people freeze, misremember, or describe things
  /// badly under pressure.
  notDemonstrated(
    'Not demonstrated',
    'This claim was probed but the response did not demonstrate it.',
  ),

  /// Something observed directly conflicts with the claim.
  contradicted(
    'Contradicted',
    'Session evidence conflicts with this claim.',
  ),

  /// Never examined. Reported explicitly so absence of evidence is visible
  /// rather than reading as a quiet pass or a quiet fail.
  notExamined(
    'Not examined',
    'No task in this session tested this claim.',
  );

  const ClaimStatus(this.label, this.description);
  final String label;
  final String description;
}

/// One piece of evidence bearing on a claim, with its provenance.
///
/// Every entry must be traceable to something that actually happened in the
/// session. A reviewer should be able to ask "how do you know that?" of any
/// line in the audit and get an answer.
class ClaimEvidence {
  const ClaimEvidence({
    required this.observation,
    required this.kind,
    required this.at,
  });

  /// Factual statement of what was observed. Measurements, not conclusions.
  final String observation;

  final EvidenceKind kind;
  final DateTime at;
}

enum EvidenceKind {
  /// A question was asked and the candidate answered.
  probeResponse,

  /// How the answer was produced (timing, revision, bulk insertion).
  processSignal,

  /// Identity verification during the window this claim was examined.
  identityCheck,
}
