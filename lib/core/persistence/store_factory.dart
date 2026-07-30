/// Resolves the [AuditStore] appropriate to the platform.
///
/// Conditional export rather than a runtime check: `dart:io` cannot be
/// compiled for web at all, so the choice has to be made at build time.
library;

export 'store_factory_stub.dart'
    if (dart.library.io) 'store_factory_io.dart';
