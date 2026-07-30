/// Platform-appropriate writer for exported audits.
library;

export 'export_writer_stub.dart'
    if (dart.library.io) 'export_writer_io.dart';
