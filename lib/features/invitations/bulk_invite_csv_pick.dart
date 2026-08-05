/// Picking a CSV file of candidates. Mirrors `features/resume/resume_pick.dart`'s
/// shape: read the file's real bytes, never fabricate content, report a read
/// failure as a failure rather than an empty file.
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';

class CsvPick {
  const CsvPick({required this.fileName, required this.text, required this.error});

  final String fileName;

  /// The file's actual text, or null if it could not be read.
  final String? text;

  /// Present whenever [text] is null — why it could not be read.
  final String? error;
}

/// Opens the platform file picker for a .csv file. Returns null if the user
/// cancels — distinct from "picked a file that could not be read".
Future<CsvPick?> pickCandidateCsv() async {
  final result = await FilePicker.pickFiles(
    type: FileType.custom,
    allowedExtensions: const ['csv'],
    withData: false,
  );

  final picked = result?.files.single;
  if (picked == null || picked.path == null) return null;

  try {
    final content = await File(picked.path!).readAsString();
    return CsvPick(fileName: picked.name, text: content, error: null);
  } catch (e) {
    return CsvPick(fileName: picked.name, text: null, error: 'Could not read this file: $e');
  }
}
