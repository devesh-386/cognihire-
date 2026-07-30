import 'audit_store.dart';

/// Web has no filesystem available to us here, so sessions live only as long as
/// the tab does.
Future<AuditStore> createAuditStore() async => InMemoryAuditStore();

/// False on this platform, and the UI says so on screen. Silently discarding a
/// reviewer's audit at the end of a session would be worse than not offering to
/// keep it at all.
const bool storageIsDurable = false;

Future<String> auditStorageLocation() async =>
    'In memory only — nothing is written to disk on this platform.';
