import 'dart:io';

import 'package:path_provider/path_provider.dart';

const bool exportSupported = true;

/// Writes the rendered audit and returns the full path it landed at.
///
/// Prefers the platform Downloads folder because the reviewer has to find this
/// file and attach it to something. Falls back to app documents where Downloads
/// is not a concept (Android), and reports the real path either way rather than
/// a friendly-sounding one the user cannot navigate to.
Future<String> writeAuditExport(
  String contents, {
  required String filename,
}) async {
  Directory? target;
  try {
    // Throws UnsupportedError on Android/iOS, where there is no such folder.
    target = await getDownloadsDirectory();
  } catch (_) {
    target = null;
  }

  target ??= await getApplicationDocumentsDirectory();

  if (!await target.exists()) {
    await target.create(recursive: true);
  }

  final file = File('${target.path}${Platform.pathSeparator}$filename');
  await file.writeAsString(contents, flush: true);
  return file.path;
}
