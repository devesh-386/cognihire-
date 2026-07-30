import 'dart:convert';
import 'dart:io';

import '../claims/claim_audit.dart';
import 'audit_store.dart';
import 'json_codec.dart';

/// File-backed [AuditStore]: one JSON file per session, plus one for the
/// enrolled reference face.
///
/// Plain files rather than a database. At demo scale the entire dataset is a
/// few dozen small documents, and a stored audit a reviewer can open in a text
/// editor is worth more to this project than query performance it will never
/// need — the deliverable is meant to be inspectable.
///
/// Takes a directory path rather than resolving one itself, so tests can point
/// it at a temporary directory and the app can point it at platform app-support
/// storage without the core knowing which is which.
class JsonFileAuditStore implements AuditStore {
  JsonFileAuditStore(this.directoryPath);

  final String directoryPath;

  static const _sessionPrefix = 'session-';
  static const _sessionSuffix = '.json';
  static const _enrolmentFile = 'enrolment.json';

  Directory get _directory => Directory(directoryPath);

  File _sessionFile(String id) =>
      File('$directoryPath${Platform.pathSeparator}$id$_sessionSuffix');

  File get _enrolmentPath =>
      File('$directoryPath${Platform.pathSeparator}$_enrolmentFile');

  Future<void> _ensureDirectory() async {
    if (!await _directory.exists()) {
      await _directory.create(recursive: true);
    }
  }

  @override
  Future<String> saveAudit(ClaimAudit audit, {required String label}) async {
    await _ensureDirectory();

    // Millisecond timestamp doubles as the sort key, so listing does not have
    // to open every file to order them.
    final id = '$_sessionPrefix${DateTime.now().millisecondsSinceEpoch}';

    final payload = <String, Object?>{
      'id': id,
      'label': label,
      'savedAt': DateTime.now().toIso8601String(),
      'audit': auditToJson(audit),
    };

    // Write to a temporary file and rename over the target. A crash mid-write
    // then leaves either the old file or the new one, never a half-written
    // audit that would read back as a shorter session than actually happened.
    final target = _sessionFile(id);
    final temp = File('${target.path}.tmp');
    await temp.writeAsString(
      const JsonEncoder.withIndent('  ').convert(payload),
      flush: true,
    );
    await temp.rename(target.path);

    return id;
  }

  @override
  Future<SessionIndex> listSessions() async {
    if (!await _directory.exists()) {
      return const SessionIndex(sessions: [], unreadable: []);
    }

    final sessions = <SessionSummary>[];
    final unreadable = <UnreadableSession>[];

    final files = await _directory
        .list()
        .where((entity) => entity is File)
        .cast<File>()
        .where((file) {
          final name = _basename(file.path);
          return name.startsWith(_sessionPrefix) &&
              name.endsWith(_sessionSuffix);
        })
        .toList();

    for (final file in files) {
      final id = _basename(file.path)
          .substring(0, _basename(file.path).length - _sessionSuffix.length);
      try {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is! Map) {
          throw const FormatException('Stored session is not a JSON object');
        }
        final record = decoded.cast<String, Object?>();
        final auditJson = record['audit'];
        if (auditJson is! Map) {
          throw const FormatException('Stored session has no "audit" object');
        }

        final audit = auditFromJson(auditJson.cast<String, Object?>());
        final label = record['label'];

        sessions.add(SessionSummary(
          id: id,
          label: label is String ? label : id,
          sessionStart: audit.sessionStart,
          sessionEnd: audit.sessionEnd,
          claimCount: audit.findings.length,
          provenanceQuality: audit.provenanceQuality,
        ));
      } on FormatException catch (error) {
        unreadable.add(UnreadableSession(id: id, problem: error.message));
      } on FileSystemException catch (error) {
        unreadable.add(UnreadableSession(id: id, problem: error.message));
      }
    }

    sessions.sort((a, b) => b.sessionEnd.compareTo(a.sessionEnd));
    unreadable.sort((a, b) => a.id.compareTo(b.id));

    return SessionIndex(sessions: sessions, unreadable: unreadable);
  }

  @override
  Future<ClaimAudit> loadAudit(String id) async {
    final file = _sessionFile(id);
    if (!await file.exists()) {
      throw StateError('No stored session with id "$id"');
    }

    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map) {
      throw const FormatException('Stored session is not a JSON object');
    }
    final auditJson = decoded.cast<String, Object?>()['audit'];
    if (auditJson is! Map) {
      throw const FormatException('Stored session has no "audit" object');
    }

    return auditFromJson(auditJson.cast<String, Object?>());
  }

  @override
  Future<void> deleteAudit(String id) async {
    final file = _sessionFile(id);
    if (await file.exists()) await file.delete();
  }

  @override
  Future<EnrolmentProfile?> loadEnrolment() async {
    final file = _enrolmentPath;
    // Absent is a real answer: nobody has enrolled. Unreadable is not — that
    // propagates as FormatException from the codec below.
    if (!await file.exists()) return null;

    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map) {
      throw const FormatException('Stored enrolment is not a JSON object');
    }
    return enrolmentProfileFromJson(decoded.cast<String, Object?>());
  }

  @override
  Future<void> saveEnrolment(EnrolmentProfile profile) async {
    await _ensureDirectory();
    final target = _enrolmentPath;
    final temp = File('${target.path}.tmp');
    await temp.writeAsString(
      const JsonEncoder.withIndent('  ')
          .convert(enrolmentProfileToJson(profile)),
      flush: true,
    );
    await temp.rename(target.path);
  }

  @override
  Future<void> clearEnrolment() async {
    final file = _enrolmentPath;
    if (await file.exists()) await file.delete();
  }

  static String _basename(String path) {
    final slash = path.lastIndexOf(RegExp(r'[/\\]'));
    return slash == -1 ? path : path.substring(slash + 1);
  }
}
