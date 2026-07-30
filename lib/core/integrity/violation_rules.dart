/// Integrity observation table.
///
/// Ported from the reference React build (`scoreEngine.js`) with a deliberate
/// removal: the reference attached a numeric `baseWeight` to every rule and
/// summed them into a 0–100 risk score. That number is gone, and the field with
/// it. A weight is only meaningful if it feeds an aggregate judgement, and this
/// project does not make one — "AI measures, humans decide." An identity
/// mismatch and a focus loss are both *observations a reviewer should see*, not
/// quantities to be added together into a verdict the machine reaches first.
///
/// Every rule here must still correspond to a signal the system can actually
/// measure. If a detector for a rule is unavailable at runtime, the rule simply
/// produces no observations — it never stands in for one.
enum ViolationRule {
  focusLoss(
    key: 'FOCUS_LOSS',
    label: 'Application Focus Lost',
    description: 'Candidate navigated away from the assessment window.',
  ),
  fullscreenExit(
    key: 'FULLSCREEN_EXIT',
    label: 'Secure Mode Exited',
    description: 'The locked assessment view was closed.',
  ),
  phoneDetected(
    key: 'PHONE_DETECTED',
    label: 'Mobile Device Visible',
    description: 'A phone or handset was detected in the workspace.',
  ),
  screenDetected(
    key: 'SCREEN_DETECTED',
    label: 'Secondary Display Visible',
    description: 'An additional monitor, TV, or laptop was detected.',
  ),
  bookDetected(
    key: 'BOOK_DETECTED',
    label: 'Reference Material Visible',
    description: 'A book or written notes were detected nearby.',
  ),
  additionalPerson(
    key: 'ADDITIONAL_PERSON',
    label: 'Additional Person Present',
    description: 'More than one person was detected in frame.',
  ),

  /// The provenance signal — the one thing conventional proctoring checks once
  /// at login and then forgets. It is reported as its own observation, not
  /// ranked above the others by a number, because ranking is the reviewer's job.
  identityMismatch(
    key: 'IDENTITY_MISMATCH',
    label: 'Identity Verification Failed',
    description:
        'The live face did not match the enrolled profile within threshold.',
  ),

  /// A softer, complementary signal to [identityMismatch]: the capture still
  /// cleared the enrolled-profile threshold, but its similarity score fell
  /// outside the range this *same candidate's own* earlier captures in this
  /// session established (`WithinSessionBaseline`, `ML_REDESIGN.md` §4.2).
  /// Reported distinctly rather than folded into `identityMismatch` because it
  /// is a different measurement: one compares against the enrolled reference,
  /// this compares against the candidate's own session-local pattern.
  selfBaselineDeviation(
    key: 'SELF_BASELINE_DEVIATION',
    label: 'Deviated From Session Baseline',
    description:
        "This capture's similarity to the enrolled reference fell outside "
        "the range the candidate's own earlier captures in this session "
        'established.',
  );

  const ViolationRule({
    required this.key,
    required this.label,
    required this.description,
  });

  final String key;
  final String label;
  final String description;

  static ViolationRule? fromKey(String key) {
    for (final rule in ViolationRule.values) {
      if (rule.key == key) return rule;
    }
    return null;
  }
}
