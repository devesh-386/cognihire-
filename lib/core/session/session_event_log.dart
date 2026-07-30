/// An append-only, hash-chained log of what happened during a session.
///
/// ## What this is for
///
/// The audit this project produces is only as trustworthy as the record it is
/// built from. A plain JSON list of events can be edited after the fact and
/// nobody is the wiser — an inconvenient identity mismatch quietly deleted, a
/// claim's timeline nudged. This log makes that visible: every entry carries the
/// SHA-256 of the entry before it, so changing, inserting, or removing any past
/// event breaks the chain from that point onward and [verifyIntegrity] says
/// exactly where.
///
/// It is tamper-*evident*, not tamper-*proof*: someone who rewrites the whole
/// file, recomputing every hash, produces a valid chain. Defeating that needs a
/// signature or an external anchor, which is future work. What this rules out is
/// the casual, surgical edit — the realistic threat for a demo and the honest
/// thing to defend against now.
///
/// ## Discipline inherited from the audit codec
///
/// Decoding is strict, matching `json_codec.dart`: an unknown event kind, a
/// missing field, or a malformed record raises [FormatException] rather than
/// defaulting. A provenance log that silently drops the record it cannot read is
/// the omission-shaped version of a fabricated pass.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

/// The kinds of event a session can record. Closed set — a new kind is a code
/// change here and a schema bump, never an arbitrary string from a caller.
enum SessionEventKind {
  sessionStarted,
  sessionEnded,
  claimOpened,
  claimAnswered,
  followUpAsked,
  identityChecked,
  integrityObserved,
  keystrokeBatch,
  resumeIngested,
  researchConsentSet;

  static SessionEventKind parse(String name, String context) {
    for (final v in SessionEventKind.values) {
      if (v.name == name) return v;
    }
    throw FormatException(
      '$context: unknown event kind "$name". '
      'Known: ${SessionEventKind.values.map((v) => v.name).join(', ')}',
    );
  }
}

/// One recorded event, plus the chain links that make it tamper-evident.
class SessionEntry {
  const SessionEntry({
    required this.sequence,
    required this.kind,
    required this.at,
    required this.payload,
    required this.previousHash,
    required this.hash,
  });

  /// 1-based position in the log.
  final int sequence;
  final SessionEventKind kind;
  final DateTime at;

  /// JSON-safe, content-only fields. Never holds a keystroke character or a raw
  /// face embedding — callers pass already-reduced values.
  final Map<String, Object?> payload;

  /// Hash of the entry before this one; [SessionEventLog.genesisHash] for the
  /// first entry.
  final String previousHash;

  /// SHA-256 over [previousHash] + this entry's canonical content.
  final String hash;

  Map<String, Object?> toJson() => {
        'seq': sequence,
        'kind': kind.name,
        'at': at.toIso8601String(),
        'payload': payload,
        'prev': previousHash,
        'hash': hash,
      };
}

/// The outcome of verifying a log's hash chain.
sealed class IntegrityResult {
  const IntegrityResult();
}

/// The chain is intact end to end.
class IntegrityOk extends IntegrityResult {
  const IntegrityOk();

  @override
  bool operator ==(Object other) => other is IntegrityOk;

  @override
  int get hashCode => 0;
}

/// The chain is broken; [firstBrokenSequence] is the 1-based sequence number of
/// the earliest entry whose stored hash does not match its recomputed value (or
/// whose `previousHash` does not match its predecessor).
class IntegrityBroken extends IntegrityResult {
  const IntegrityBroken(this.firstBrokenSequence, this.detail);

  final int firstBrokenSequence;
  final String detail;

  @override
  bool operator ==(Object other) =>
      other is IntegrityBroken &&
      other.firstBrokenSequence == firstBrokenSequence;

  @override
  int get hashCode => firstBrokenSequence;
}

class SessionEventLog {
  SessionEventLog();

  /// The `previousHash` of the very first entry — a fixed, well-known anchor so
  /// that "no predecessor" is itself a hashed, checkable fact.
  static const String genesisHash =
      '0000000000000000000000000000000000000000000000000000000000000000';

  final List<SessionEntry> _entries = [];

  List<SessionEntry> get entries => List.unmodifiable(_entries);

  /// Append an event and return the created entry.
  ///
  /// [payload] is deep-copied through JSON so that a caller mutating their map
  /// afterwards cannot alter recorded — and hashed — history.
  SessionEntry append(
    SessionEventKind kind, {
    required DateTime at,
    Map<String, Object?> payload = const {},
  }) {
    final frozen = _freeze(payload);
    final previousHash = _entries.isEmpty ? genesisHash : _entries.last.hash;
    final sequence = _entries.length + 1;
    final hash = _computeHash(
      previousHash: previousHash,
      kind: kind,
      at: at,
      payload: frozen,
    );

    final entry = SessionEntry(
      sequence: sequence,
      kind: kind,
      at: at,
      payload: frozen,
      previousHash: previousHash,
      hash: hash,
    );
    _entries.add(entry);
    return entry;
  }

  /// Recompute the whole chain and report the first place it diverges.
  IntegrityResult verifyIntegrity() {
    var expectedPrev = genesisHash;
    for (final entry in _entries) {
      if (entry.previousHash != expectedPrev) {
        return IntegrityBroken(
          entry.sequence,
          'previousHash does not match the preceding entry',
        );
      }
      final recomputed = _computeHash(
        previousHash: entry.previousHash,
        kind: entry.kind,
        at: entry.at,
        payload: entry.payload,
      );
      if (recomputed != entry.hash) {
        return IntegrityBroken(
          entry.sequence,
          'stored hash does not match recomputed content',
        );
      }
      expectedPrev = entry.hash;
    }
    return const IntegrityOk();
  }

  /// One JSON object per line. An empty log is the empty string, not a blank
  /// line that would parse as a malformed record.
  String toJsonl() =>
      _entries.map((e) => jsonEncode(e.toJson())).join('\n');

  /// Rebuild a log from JSONL. Does not itself judge integrity — call
  /// [verifyIntegrity] after — but does refuse structurally invalid records.
  static SessionEventLog fromJsonl(String jsonl) {
    final log = SessionEventLog();
    for (final line in jsonl.split('\n')) {
      if (line.trim().isEmpty) continue;
      log._entries.add(_entryFromJson(line));
    }
    return log;
  }

  // -------------------------------------------------------------------------

  static Map<String, Object?> _freeze(Map<String, Object?> payload) {
    // Round-trip through JSON: rejects non-encodable values early and detaches
    // from the caller's reference in one step.
    final encoded = jsonEncode(payload);
    return (jsonDecode(encoded) as Map).cast<String, Object?>();
  }

  /// Canonical bytes → SHA-256. Canonical means: the predecessor hash, then the
  /// content with **sorted keys**, so that map iteration order can never change
  /// the hash of identical content.
  static String _computeHash({
    required String previousHash,
    required SessionEventKind kind,
    required DateTime at,
    required Map<String, Object?> payload,
  }) {
    final canonicalContent = _canonicalJson({
      'kind': kind.name,
      'at': at.toIso8601String(),
      'payload': payload,
    });
    final bytes = utf8.encode('$previousHash|$canonicalContent');
    return sha256.convert(bytes).toString();
  }

  /// JSON with every map's keys sorted, recursively. Deterministic regardless of
  /// insertion order.
  static String _canonicalJson(Object? value) {
    final buffer = StringBuffer();
    _writeCanonical(value, buffer);
    return buffer.toString();
  }

  static void _writeCanonical(Object? value, StringBuffer out) {
    if (value is Map) {
      final keys = value.keys.map((k) => k.toString()).toList()..sort();
      out.write('{');
      for (var i = 0; i < keys.length; i++) {
        if (i > 0) out.write(',');
        out.write(jsonEncode(keys[i]));
        out.write(':');
        _writeCanonical(value[keys[i]], out);
      }
      out.write('}');
    } else if (value is List) {
      out.write('[');
      for (var i = 0; i < value.length; i++) {
        if (i > 0) out.write(',');
        _writeCanonical(value[i], out);
      }
      out.write(']');
    } else {
      out.write(jsonEncode(value));
    }
  }

  static SessionEntry _entryFromJson(String line) {
    const context = 'SessionEntry';
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException catch (e) {
      throw FormatException('$context: line is not valid JSON: ${e.message}');
    }
    if (decoded is! Map) {
      throw const FormatException('$context: record is not a JSON object');
    }
    final json = decoded.cast<String, Object?>();

    final seq = json['seq'];
    if (seq is! int) {
      throw const FormatException('$context: missing or non-int "seq"');
    }
    final kindName = json['kind'];
    if (kindName is! String) {
      throw const FormatException('$context: missing "kind"');
    }
    final atRaw = json['at'];
    if (atRaw is! String) {
      throw const FormatException('$context: missing "at"');
    }
    final at = DateTime.tryParse(atRaw);
    if (at == null) {
      throw FormatException('$context: "at" is not ISO-8601: "$atRaw"');
    }
    final payloadRaw = json['payload'];
    if (payloadRaw is! Map) {
      throw const FormatException('$context: missing "payload" object');
    }
    final prev = json['prev'];
    if (prev is! String) {
      throw const FormatException('$context: missing "prev"');
    }
    final hash = json['hash'];
    if (hash is! String) {
      throw const FormatException('$context: missing "hash"');
    }

    return SessionEntry(
      sequence: seq,
      kind: SessionEventKind.parse(kindName, context),
      at: at,
      payload: payloadRaw.cast<String, Object?>(),
      previousHash: prev,
      hash: hash,
    );
  }
}
