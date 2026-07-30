import 'package:path_provider/path_provider.dart';

import 'audit_store.dart';
import 'audit_store_io.dart';

/// Platforms with a filesystem get durable storage under app-support.
///
/// `getApplicationSupportDirectory()` already resolves to a directory scoped
/// to this app's own bundle identifier (on Windows: CompanyName\ProductName
/// under AppData\Roaming) — it is not a shared directory that needs a
/// sub-folder to avoid collisions. An earlier version of this file appended
/// `/cognihire` again, which both hardcoded a forward slash on a platform
/// whose separator is `\`, and doubled the app name into a path like
/// `...\com.cognihire\cognihire\cognihire`. Neither wrong on its own would
/// have been very visible; together they showed up as a garbled path on the
/// home screen, once a person actually looked at it.
Future<AuditStore> createAuditStore() async {
  final base = await getApplicationSupportDirectory();
  return JsonFileAuditStore(base.path);
}

/// Whether anything saved here survives a restart. The UI states this rather
/// than letting an operator assume it — a demo that quietly loses its sessions
/// is the same class of problem as a check that quietly passes.
const bool storageIsDurable = true;

Future<String> auditStorageLocation() async {
  final base = await getApplicationSupportDirectory();
  return base.path;
}
