/// Resolves the [RoleStore] appropriate to the platform.
///
/// Conditional export rather than a runtime check, matching
/// `persistence/store_factory.dart`: `dart:io` cannot be compiled for web at
/// all, so the choice has to be made at build time.
library;

export 'role_store_factory_stub.dart'
    if (dart.library.io) 'role_store_factory_io.dart';
