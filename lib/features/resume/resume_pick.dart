/// Picking a resume file and reading whatever text it actually contains.
///
/// ## Why this exists, and what it deliberately does not do
///
/// The reference build this project learns from has a "resume upload"
/// feature that never reads the file at all: it guesses a category from the
/// *filename string* and returns one of sixteen hardcoded score blocks, with
/// a fake progress bar to make the guess feel like analysis. The backend
/// route it's meant to call exists but is never invoked, and the one that
/// does run ignores the upload and parses a hardcoded constant instead.
///
/// So the one rule for this file: **never return text the file doesn't
/// actually contain.** For `.txt`, the content is read directly — no
/// parsing library, no failure mode to fabricate around. For `.pdf` and
/// `.docx`, this project does not yet have a working text extractor, and
/// [ResumePick.extractionNote] says so plainly rather than presenting a blank
/// or guessed result as a successful read.
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';

/// What came back from picking a file.
class ResumePick {
  const ResumePick({
    required this.fileName,
    required this.filePath,
    required this.text,
    required this.extractionNote,
  });

  final String fileName;
  final String filePath;

  /// The resume's actual text, or null if this format isn't read yet.
  /// Never a guessed or templated stand-in for real content.
  final String? text;

  /// Present whenever [text] is null — explains *why*, so the gap is visible
  /// rather than looking like an empty resume.
  final String? extractionNote;

  bool get hasText => text != null && text!.trim().isNotEmpty;
}

const _supportedExtensions = ['txt', 'pdf', 'docx'];

/// Opens the platform file picker. Returns null if the user cancels — that is
/// a real, distinct outcome from "picked a file with no readable text", and
/// callers should not conflate the two.
Future<ResumePick?> pickResume() async {
  final result = await FilePicker.pickFiles(
    type: FileType.custom,
    allowedExtensions: _supportedExtensions,
    withData: false,
  );

  final picked = result?.files.single;
  if (picked == null || picked.path == null) return null;

  final path = picked.path!;
  final extension = picked.extension?.toLowerCase() ?? '';

  if (extension == 'txt') {
    try {
      final content = await File(path).readAsString();
      return ResumePick(
        fileName: picked.name,
        filePath: path,
        text: content,
        extractionNote: null,
      );
    } catch (e) {
      // A read failure is reported as a failure, not as an empty resume.
      return ResumePick(
        fileName: picked.name,
        filePath: path,
        text: null,
        extractionNote: 'Could not read this file: $e',
      );
    }
  }

  // .pdf / .docx: no extractor wired up yet. Say so — the alternative is
  // exactly the failure mode this file exists to avoid.
  return ResumePick(
    fileName: picked.name,
    filePath: path,
    text: null,
    extractionNote: 'Text extraction for .$extension files isn\'t wired up '
        'yet in this build — only .txt is read directly right now. The file '
        'is attached, but its content is not shown or used.',
  );
}
