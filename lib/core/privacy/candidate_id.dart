import 'dart:convert';

import 'package:crypto/crypto.dart';

/// A candidate identifier derived by HMAC-SHA256, not stored or displayed
/// against any directly identifying value.
///
/// ## Why HMAC and not a plain hash
///
/// A plain `sha256("alice@example.com")` is a *pseudonym*, not an
/// anonymisation: anyone who guesses the input (or runs a dictionary of likely
/// emails) can recompute the same hash and re-identify the candidate. Keying
/// the hash with a secret closes that off — recomputing the id requires the
/// secret, which is held by the party doing the linking (this project's
/// research-release process), not by whoever ends up with the dataset.
/// Changing the secret between release batches makes ids **non-linkable**
/// across batches by design: the same candidate, released twice under two
/// different keys, gets two ids that cannot be connected without both keys.
class CandidateId {
  const CandidateId._(this.value);

  /// Lowercase hex digest. Fixed length regardless of the seed's length.
  final String value;

  /// Derive a candidate id from [seed] (an email, a name, any identifying
  /// string) under [secret] (the batch's release key, held separately from the
  /// dataset).
  factory CandidateId.derive({required String secret, required String seed}) {
    if (secret.isEmpty) {
      throw ArgumentError.value(secret, 'secret',
          'must not be empty — an unkeyed hash is a pseudonym, not an HMAC');
    }
    if (seed.isEmpty) {
      throw ArgumentError.value(seed, 'seed', 'must not be empty');
    }
    final hmac = Hmac(sha256, utf8.encode(secret));
    final digest = hmac.convert(utf8.encode(seed));
    return CandidateId._(digest.toString());
  }

  @override
  String toString() => value;

  @override
  bool operator ==(Object other) =>
      other is CandidateId && other.value == value;

  @override
  int get hashCode => value.hashCode;
}
