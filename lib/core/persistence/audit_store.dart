import '../claims/claim_audit.dart';
import 'json_codec.dart';

/// A saved session, listed without loading the whole audit.
///
/// Carries only what a "past sessions" list needs to render. The counts are
/// recomputed from the audit at save time, never authored separately.
class SessionSummary {
  const SessionSummary({
    required this.id,
    required this.label,
    required this.sessionStart,
    required this.sessionEnd,
    required this.claimCount,
    required this.provenanceQuality,
  });

  final String id;

  /// Human-facing name for the session. Whatever the operator typed; the store
  /// does not invent one.
  final String label;

  final DateTime sessionStart;
  final DateTime sessionEnd;
  final int claimCount;

  /// Recomputed from the stored attempts on load, not stored as a verdict.
  final ProvenanceQuality provenanceQuality;

  Duration get duration => sessionEnd.difference(sessionStart);
}

/// A stored session that could not be read back.
///
/// Surfaced rather than skipped. A corrupt audit silently vanishing from the
/// list would leave a reviewer believing they had seen every session — the same
/// class of error as a fabricated pass, arrived at by omission.
class UnreadableSession {
  const UnreadableSession({required this.id, required this.problem});

  final String id;
  final String problem;
}

/// The result of listing stored sessions: what was readable, and what was not.
class SessionIndex {
  const SessionIndex({required this.sessions, required this.unreadable});

  final List<SessionSummary> sessions;
  final List<UnreadableSession> unreadable;

  bool get hasUnreadable => unreadable.isNotEmpty;
  int get total => sessions.length + unreadable.length;
}

/// Persistence for completed audits and the enrolled reference face.
///
/// Abstract so the core stays free of `dart:io` and remains testable in plain
/// Dart. The file-backed implementation lives in `audit_store_io.dart`.
abstract class AuditStore {
  /// Saves an audit and returns the id it was stored under.
  Future<String> saveAudit(ClaimAudit audit, {required String label});

  /// Lists stored sessions newest first, reporting unreadable ones separately.
  Future<SessionIndex> listSessions();

  /// Loads one audit. Throws [FormatException] if the stored record is not
  /// readable, and [StateError] if no session has that id.
  Future<ClaimAudit> loadAudit(String id);

  Future<void> deleteAudit(String id);

  /// The enrolled reference face, or null if nobody has enrolled yet.
  ///
  /// Throws [FormatException] if a profile exists but cannot be read — an
  /// unreadable reference must not present as "not enrolled", because the
  /// session that follows would then run with identity unverified while looking
  /// like a deliberate choice.
  Future<EnrolmentProfile?> loadEnrolment();

  Future<void> saveEnrolment(EnrolmentProfile profile);

  Future<void> clearEnrolment();
}

/// In-memory store. Used by tests, and by platforms where no filesystem is
/// available — in which case the UI must say that nothing will survive
/// restart rather than letting the user assume it will.
class InMemoryAuditStore implements AuditStore {
  final Map<String, ClaimAudit> _audits = {};
  final Map<String, String> _labels = {};
  EnrolmentProfile? _enrolment;
  int _nextId = 1;

  @override
  Future<String> saveAudit(ClaimAudit audit, {required String label}) async {
    final id = 'session-${_nextId++}';
    _audits[id] = audit;
    _labels[id] = label;
    return id;
  }

  @override
  Future<SessionIndex> listSessions() async {
    final sessions = _audits.entries
        .map((entry) => SessionSummary(
              id: entry.key,
              label: _labels[entry.key] ?? entry.key,
              sessionStart: entry.value.sessionStart,
              sessionEnd: entry.value.sessionEnd,
              claimCount: entry.value.findings.length,
              provenanceQuality: entry.value.provenanceQuality,
            ))
        .toList()
      ..sort((a, b) => b.sessionEnd.compareTo(a.sessionEnd));

    return SessionIndex(sessions: sessions, unreadable: const []);
  }

  @override
  Future<ClaimAudit> loadAudit(String id) async {
    final audit = _audits[id];
    if (audit == null) throw StateError('No stored session with id "$id"');
    return audit;
  }

  @override
  Future<void> deleteAudit(String id) async {
    _audits.remove(id);
    _labels.remove(id);
  }

  @override
  Future<EnrolmentProfile?> loadEnrolment() async => _enrolment;

  @override
  Future<void> saveEnrolment(EnrolmentProfile profile) async {
    _enrolment = profile;
  }

  @override
  Future<void> clearEnrolment() async {
    _enrolment = null;
  }
}
