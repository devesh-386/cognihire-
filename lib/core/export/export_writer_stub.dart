const bool exportSupported = false;

/// Web has no filesystem here. The button is disabled rather than present and
/// silently doing nothing.
Future<String> writeAuditExport(
  String contents, {
  required String filename,
}) async {
  throw UnsupportedError('Exporting to a file is not available on this platform');
}

/// [writeAuditExport]'s counterpart for binary files — same platform gap,
/// same refusal rather than a silent no-op.
Future<String> writeBinaryExport(
  List<int> bytes, {
  required String filename,
}) async {
  throw UnsupportedError('Exporting to a file is not available on this platform');
}
