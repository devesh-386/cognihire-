const bool exportSupported = false;

/// Web has no filesystem here. The button is disabled rather than present and
/// silently doing nothing.
Future<String> writeAuditExport(
  String contents, {
  required String filename,
}) async {
  throw UnsupportedError('Exporting to a file is not available on this platform');
}
