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
/// actually contain.** For `.txt`, the content is read directly — no parsing
/// library, no failure mode to fabricate around. For `.pdf` and `.docx`,
/// `resume_text_extraction.dart` reads the real document on this device, and
/// when it cannot — an encrypted PDF, or a scan with no text layer — the reason
/// is reported in [ResumePick.extractionNote] rather than a blank result being
/// presented as a successful read of an empty resume.
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';

import 'resume_text_extraction.dart';

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

  if (extension == 'pdf' || extension == 'docx') {
    final List<int> bytes;
    try {
      bytes = await File(path).readAsBytes();
    } catch (e) {
      return ResumePick(
        fileName: picked.name,
        filePath: path,
        text: null,
        extractionNote: 'Could not read this file: $e',
      );
    }

    // Both extractors run on this device. Nothing is uploaded, which is the
    // reason a cloud parsing service was never an option here.
    final extracted = extension == 'pdf'
        ? extractPdfText(bytes)
        : extractDocxText(bytes);

    return ResumePick(
      fileName: picked.name,
      filePath: path,
      text: extracted.text,
      extractionNote: extracted.reason,
    );
  }

  // An extension the picker should not have allowed through. Reported rather
  // than silently treated as unreadable, because it means the allow-list and
  // this switch have drifted apart.
  return ResumePick(
    fileName: picked.name,
    filePath: path,
    text: null,
    extractionNote: 'This build does not read .$extension files.',
  );
}
