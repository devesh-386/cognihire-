import 'claim.dart';

/// How a set of claims was produced. Carried with the claims themselves so a
/// reviewer is never left guessing whether a line came from a language model or
/// from a text rule.
///
/// This project's whole position is provenance over verdict. A claim list with
/// no recorded origin would be the same category of failure as a score with no
/// derivation.
enum ExtractorKind {
  /// Shape-and-length rules only. No understanding of meaning.
  heuristicRule('Text rules', 'Selected by line shape and length. Nothing here '
      'read the resume for meaning.'),

  /// A language model running locally on this machine. Nothing was sent to a
  /// third party.
  localLlm('Local model', 'Extracted by a language model running on this '
      'machine. The resume text was not sent anywhere.');

  const ExtractorKind(this.label, this.description);
  final String label;
  final String description;
}

/// The result of extraction: the claims, where they came from, and what was
/// thrown away getting there.
class ClaimExtraction {
  const ClaimExtraction({
    required this.claims,
    required this.kind,
    this.degradedReason,
    this.rejectedUngrounded = const [],
  });

  final List<Claim> claims;

  /// Which mechanism actually produced [claims] — the *effective* one, not the
  /// one that was asked for. A fallback reports the fallback's kind.
  final ExtractorKind kind;

  /// Non-null when the requested extractor could not be used and something else
  /// ran instead. Surfaced to the user, never swallowed: silently degrading to
  /// weaker extraction while the UI still implies a model ran would misrepresent
  /// where the claims came from.
  final String? degradedReason;

  /// Text a model returned that could not be found in the source document, and
  /// was therefore discarded. Kept rather than dropped quietly — a model
  /// inventing claims is exactly the failure this system exists to refuse, so it
  /// should be visible when it happens.
  final List<String> rejectedUngrounded;

  bool get isDegraded => degradedReason != null;
}

/// Anything that can turn a document into candidate claims.
///
/// Deliberately provider-agnostic: the choice between a local model, a rule, or
/// some future hosted API is a configuration decision, not an architectural
/// one. Implementations must never throw for an unavailable backend — an
/// extractor that crashes the session because a server is down is worse than
/// one that degrades and says so.
abstract interface class ClaimExtractor {
  Future<ClaimExtraction> extract(String documentText,
      {required String source});
}
