/// JSON encoding and decoding for the audit domain model.
///
/// DESIGN RULE — decoding is strict and throws on anything it does not
/// recognise. It never substitutes a default.
///
/// The rest of this codebase refuses to let "could not measure" decay into
/// "passed" (`Unchecked` carries no similarity; the face service returns a null
/// embedding rather than a zero-vector). Persistence is where that discipline is
/// easiest to lose: a truncated file or a renamed enum silently becomes
/// `Verified(similarity: 0)` if the decoder is written the usual forgiving way,
/// and a fabricated pass that came off disk is indistinguishable from a real
/// one.
///
/// So a record either round-trips exactly or it raises [FormatException]. A
/// stored audit that cannot be read is reported as unreadable, which a reviewer
/// can act on. A stored audit that reads back subtly wrong is the failure this
/// project exists to argue against.
library;

import '../claims/claim.dart';
import '../claims/claim_audit.dart';
import '../session/session_event_log.dart';
import '../verification/verification_result.dart';

/// Bumped when the on-disk shape changes incompatibly. Decoding refuses a
/// version it was not written for rather than guessing at the difference.
///
/// v2 added the session event log (`sessionEvents`) to the audit record.
const int auditSchemaVersion = 2;

// ---------------------------------------------------------------------------
// Strict field readers
// ---------------------------------------------------------------------------

Object? _require(Map<String, Object?> json, String key, String context) {
  if (!json.containsKey(key)) {
    throw FormatException('$context: missing required field "$key"');
  }
  return json[key];
}

String _readString(Map<String, Object?> json, String key, String context) {
  final value = _require(json, key, context);
  if (value is! String) {
    throw FormatException(
      '$context: field "$key" expected String, got ${value.runtimeType}',
    );
  }
  return value;
}

/// Reads a field that is allowed to be absent or null, but if present must be a
/// String. Absent and null both mean "not stated" — never the empty string,
/// which would claim the candidate wrote something they did not.
String? _readNullableString(
  Map<String, Object?> json,
  String key,
  String context,
) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String) {
    throw FormatException(
      '$context: field "$key" expected String or null, got ${value.runtimeType}',
    );
  }
  return value;
}

double _readDouble(Map<String, Object?> json, String key, String context) {
  final value = _require(json, key, context);
  if (value is num) return value.toDouble();
  throw FormatException(
    '$context: field "$key" expected num, got ${value.runtimeType}',
  );
}

int _readInt(Map<String, Object?> json, String key, String context) {
  final value = _require(json, key, context);
  if (value is int) return value;
  throw FormatException(
    '$context: field "$key" expected int, got ${value.runtimeType}',
  );
}

DateTime _readTime(Map<String, Object?> json, String key, String context) {
  final raw = _readString(json, key, context);
  final parsed = DateTime.tryParse(raw);
  if (parsed == null) {
    throw FormatException('$context: field "$key" is not an ISO-8601 time: "$raw"');
  }
  return parsed;
}

List<Map<String, Object?>> _readObjectList(
  Map<String, Object?> json,
  String key,
  String context,
) {
  final value = _require(json, key, context);
  if (value is! List) {
    throw FormatException(
      '$context: field "$key" expected List, got ${value.runtimeType}',
    );
  }
  return value.map((element) {
    if (element is! Map) {
      throw FormatException(
        '$context: "$key" contains a ${element.runtimeType}, expected an object',
      );
    }
    return element.cast<String, Object?>();
  }).toList();
}

/// Resolves an enum by its declared name. An unrecognised name throws rather
/// than falling back to the first value — a renamed [ClaimStatus] must not
/// quietly reread as `substantiated`.
T _readEnum<T extends Enum>(
  List<T> values,
  Map<String, Object?> json,
  String key,
  String context,
) {
  final name = _readString(json, key, context);
  for (final value in values) {
    if (value.name == name) return value;
  }
  throw FormatException(
    '$context: field "$key" has unknown value "$name". '
    'Known values: ${values.map((v) => v.name).join(', ')}',
  );
}

// ---------------------------------------------------------------------------
// Claim
// ---------------------------------------------------------------------------

Map<String, Object?> claimToJson(Claim claim) => {
      'id': claim.id,
      'text': claim.text,
      'source': claim.source,
      'skill': claim.skill,
    };

Claim claimFromJson(Map<String, Object?> json) {
  const context = 'Claim';
  return Claim(
    id: _readString(json, 'id', context),
    text: _readString(json, 'text', context),
    source: _readString(json, 'source', context),
    skill: _readNullableString(json, 'skill', context),
  );
}

// ---------------------------------------------------------------------------
// ClaimEvidence
// ---------------------------------------------------------------------------

Map<String, Object?> evidenceToJson(ClaimEvidence evidence) => {
      'observation': evidence.observation,
      'kind': evidence.kind.name,
      'at': evidence.at.toIso8601String(),
    };

ClaimEvidence evidenceFromJson(Map<String, Object?> json) {
  const context = 'ClaimEvidence';
  return ClaimEvidence(
    observation: _readString(json, 'observation', context),
    kind: _readEnum(EvidenceKind.values, json, 'kind', context),
    at: _readTime(json, 'at', context),
  );
}

// ---------------------------------------------------------------------------
// VerificationResult — tagged union
// ---------------------------------------------------------------------------

Map<String, Object?> verificationResultToJson(VerificationResult result) {
  // Written as an exhaustive switch so adding a variant to the sealed class is
  // a compile error here, not a silent gap that drops attempts on save.
  return switch (result) {
    Verified(:final similarity, :final at) => {
        'type': 'verified',
        'similarity': similarity,
        'at': at.toIso8601String(),
      },
    Mismatch(
      :final similarity,
      :final strike,
      :final strikesAllowed,
      :final at
    ) =>
      {
        'type': 'mismatch',
        'similarity': similarity,
        'strike': strike,
        'strikesAllowed': strikesAllowed,
        'at': at.toIso8601String(),
      },
    // Deliberately no similarity key. There was no measurement, so there is no
    // number, and writing one — even null — invites a reader to treat the field
    // as merely absent rather than inapplicable.
    Unchecked(:final reason, :final at) => {
        'type': 'unchecked',
        'reason': reason.name,
        'at': at.toIso8601String(),
      },
  };
}

VerificationResult verificationResultFromJson(Map<String, Object?> json) {
  const context = 'VerificationResult';
  final type = _readString(json, 'type', context);

  switch (type) {
    case 'verified':
      return Verified(
        similarity: _readDouble(json, 'similarity', 'Verified'),
        at: _readTime(json, 'at', 'Verified'),
      );
    case 'mismatch':
      return Mismatch(
        similarity: _readDouble(json, 'similarity', 'Mismatch'),
        strike: _readInt(json, 'strike', 'Mismatch'),
        strikesAllowed: _readInt(json, 'strikesAllowed', 'Mismatch'),
        at: _readTime(json, 'at', 'Mismatch'),
      );
    case 'unchecked':
      return Unchecked(
        reason: _readEnum(
          UncheckedReason.values,
          json,
          'reason',
          'Unchecked',
        ),
        at: _readTime(json, 'at', 'Unchecked'),
      );
    default:
      // Not recoverable, and deliberately not recovered from. An unknown
      // attempt type could be anything; the one thing it must never become is
      // a verified one.
      throw FormatException(
        '$context: unknown attempt type "$type". '
        'Known types: verified, mismatch, unchecked',
      );
  }
}

// ---------------------------------------------------------------------------
// ClaimFinding
// ---------------------------------------------------------------------------

Map<String, Object?> findingToJson(ClaimFinding finding) => {
      'claim': claimToJson(finding.claim),
      'status': finding.status.name,
      'evidence': finding.evidence.map(evidenceToJson).toList(),
    };

ClaimFinding findingFromJson(Map<String, Object?> json) {
  const context = 'ClaimFinding';
  final claimJson = _require(json, 'claim', context);
  if (claimJson is! Map) {
    throw FormatException(
      '$context: field "claim" expected object, got ${claimJson.runtimeType}',
    );
  }

  return ClaimFinding(
    claim: claimFromJson(claimJson.cast<String, Object?>()),
    status: _readEnum(ClaimStatus.values, json, 'status', context),
    evidence: List.unmodifiable(
      _readObjectList(json, 'evidence', context).map(evidenceFromJson),
    ),
  );
}

// ---------------------------------------------------------------------------
// ClaimAudit
// ---------------------------------------------------------------------------

/// Note what is *not* written: `identityCoverage`, `provenanceQuality` and
/// `summary` are all derived. Storing them would let a stored file disagree
/// with the rules that produce them, and the file would win on reload. They are
/// recomputed from the attempts every time the audit is read.
Map<String, Object?> auditToJson(ClaimAudit audit) => {
      'schemaVersion': auditSchemaVersion,
      'sessionStart': audit.sessionStart.toIso8601String(),
      'sessionEnd': audit.sessionEnd.toIso8601String(),
      'findings': audit.findings.map(findingToJson).toList(),
      'identityAttempts':
          audit.identityAttempts.map(verificationResultToJson).toList(),
      // The tamper-evident event log travels with the audit. Empty string when
      // no events were recorded — never absent, so a reader can tell "no events"
      // from "old format".
      'sessionEvents': audit.sessionEventsJsonl,
    };

ClaimAudit auditFromJson(Map<String, Object?> json) {
  const context = 'ClaimAudit';

  final version = _readInt(json, 'schemaVersion', context);
  if (version != auditSchemaVersion) {
    throw FormatException(
      '$context: stored schema version $version cannot be read by this build '
      '(expects $auditSchemaVersion)',
    );
  }

  final sessionEvents = _readString(json, 'sessionEvents', context);
  // Re-verify the hash chain at the persistence boundary. A stored log that was
  // edited on disk is exactly the "fabricated pass that came off disk" this
  // codec exists to refuse — so a broken chain is a FormatException, not a
  // quietly-loaded record. Parsing itself already rejects malformed lines.
  final integrity = SessionEventLog.fromJsonl(sessionEvents).verifyIntegrity();
  if (integrity is IntegrityBroken) {
    throw FormatException(
      '$context: stored session event log fails integrity at entry '
      '${integrity.firstBrokenSequence} (${integrity.detail})',
    );
  }

  return ClaimAudit(
    findings: List.unmodifiable(
      _readObjectList(json, 'findings', context).map(findingFromJson),
    ),
    sessionStart: _readTime(json, 'sessionStart', context),
    sessionEnd: _readTime(json, 'sessionEnd', context),
    identityAttempts: List.unmodifiable(
      _readObjectList(json, 'identityAttempts', context)
          .map(verificationResultFromJson),
    ),
    sessionEventsJsonl: sessionEvents,
  );
}

// ---------------------------------------------------------------------------
// Enrolment profile
// ---------------------------------------------------------------------------

/// The reference face captured at enrolment, plus when it was taken.
///
/// Persisting this is what makes a multi-run demo possible: enrol once, then
/// run several interviews against the same reference rather than re-enrolling
/// each time and comparing against a different capture.
class EnrolmentProfile {
  const EnrolmentProfile({
    required this.embedding,
    required this.capturedAt,
    required this.faceSize,
  });

  /// 512-d ArcFace embedding. Never a zero-vector — the service returns null
  /// when it cannot measure, and enrolment rejects that before reaching here.
  final List<double> embedding;
  final DateTime capturedAt;

  /// Detected face size at capture, kept so a reviewer can see whether the
  /// reference itself was a good one.
  final int faceSize;
}

Map<String, Object?> enrolmentProfileToJson(EnrolmentProfile profile) => {
      'schemaVersion': auditSchemaVersion,
      'embedding': profile.embedding,
      'capturedAt': profile.capturedAt.toIso8601String(),
      'faceSize': profile.faceSize,
    };

EnrolmentProfile enrolmentProfileFromJson(Map<String, Object?> json) {
  const context = 'EnrolmentProfile';

  final version = _readInt(json, 'schemaVersion', context);
  if (version != auditSchemaVersion) {
    throw FormatException(
      '$context: stored schema version $version cannot be read by this build '
      '(expects $auditSchemaVersion)',
    );
  }

  final raw = _require(json, 'embedding', context);
  if (raw is! List) {
    throw FormatException(
      '$context: field "embedding" expected List, got ${raw.runtimeType}',
    );
  }
  if (raw.isEmpty) {
    // An empty embedding compares against nothing. Loading it would produce
    // comparisons that look real and mean nothing.
    throw FormatException('$context: stored embedding is empty');
  }

  final embedding = raw.map((element) {
    if (element is! num) {
      throw FormatException(
        '$context: embedding contains a ${element.runtimeType}, expected num',
      );
    }
    return element.toDouble();
  }).toList(growable: false);

  return EnrolmentProfile(
    embedding: List.unmodifiable(embedding),
    capturedAt: _readTime(json, 'capturedAt', context),
    faceSize: _readInt(json, 'faceSize', context),
  );
}
