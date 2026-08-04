import 'package:path_provider/path_provider.dart';

import 'role_store.dart';
import 'role_store_io.dart';

/// Roles live beside the audits, in the same app-support directory, so the whole
/// local dataset is one inspectable folder.
Future<RoleStore> createRoleStore() async {
  final base = await getApplicationSupportDirectory();
  return JsonFileRoleStore(base.path);
}
