import 'role_store.dart';

/// Web has no filesystem here, so roles last only as long as the tab. The
/// Settings screen already reports that storage is not durable on this platform;
/// this store inherits that statement rather than making a second promise.
Future<RoleStore> createRoleStore() async => InMemoryRoleStore();
