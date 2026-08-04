/// Fixture: deliberately violates ED-03/ED-04. Used ONLY by
/// tools/lint/test_vocab_ban.py to prove the linter catches a real
/// violation — never scanned as part of the real lib/ tree.
class CandidateDecision {
  final double overallScore;
  final bool hireDecision;

  const CandidateDecision({
    required this.overallScore,
    required this.hireDecision,
  });
}
