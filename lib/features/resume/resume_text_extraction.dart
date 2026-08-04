/// Turning PDF and DOCX bytes into the text they actually contain.
///
/// ## The rule these functions exist to keep
///
/// The reference build this project learns from "parsed" resumes by guessing a
/// category from the *filename* and returning one of sixteen hardcoded score
/// blocks. Nothing was ever read. That is the failure mode every function here
/// is written against, so the contract is narrow and absolute:
///
/// **Return the document's own text, or return null. Never anything in
/// between.** No placeholder, no partial guess, no empty string standing in for
/// a document that could not be opened — because downstream, `hasText` treats
/// blank as "a resume with nothing in it", which is a different and much
/// quieter lie than "this file could not be read".
///
/// ## Why extraction can legitimately fail, and why that is reported
///
/// A PDF has no obligation to contain text at all. A scanned or photographed
/// resume is an image in a PDF wrapper, and extracting from it yields nothing —
/// correctly, because there is no text there, only pixels of text. Reading that
/// as an empty resume would be wrong; it needs OCR, which this build does not
/// do. [ExtractedText.reason] carries that distinction to the UI so the user is
/// told their file is a scan rather than being shown a blank result.
library;

import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:xml/xml.dart';

/// The outcome of trying to read a document.
///
/// A sealed-ish pair rather than a bare `String?`: the caller has to distinguish
/// "read it, here is the text" from "could not read it, here is why", and a null
/// string alone cannot carry the why.
class ExtractedText {
  const ExtractedText.success(this.text)
      : reason = null,
        assert(text != null);

  const ExtractedText.failure(this.reason) : text = null;

  /// The document's text, or null when extraction did not succeed.
  final String? text;

  /// Why [text] is null. Non-null exactly when [text] is null.
  final String? reason;

  bool get succeeded => text != null;
}

/// Extracts text from PDF bytes.
///
/// Returns a failure — never an empty success — when the PDF holds no extractable
/// text, which is the normal result for a scanned document.
ExtractedText extractPdfText(List<int> bytes) {
  PdfDocument? document;
  try {
    document = PdfDocument(inputBytes: bytes);
    final raw = PdfTextExtractor(document).extractText();
    final cleaned = _tidy(raw);

    if (cleaned.isEmpty) {
      return const ExtractedText.failure(
        'This PDF contains no extractable text. That usually means it is a '
        'scan or photograph of a resume rather than a text document — the '
        'words are pixels, not characters. Reading text out of an image needs '
        'OCR, which this build does not do. Export or save the resume as a '
        'text-based PDF, or attach a .txt or .docx version.',
      );
    }
    return ExtractedText.success(cleaned);
  } catch (error) {
    // Includes encrypted and malformed files. Reported as a failure to read,
    // never as a resume that happened to be empty.
    return ExtractedText.failure(
      'This PDF could not be opened: $error. If it is password-protected, '
      'remove the protection and try again.',
    );
  } finally {
    document?.dispose();
  }
}

/// Extracts text from DOCX bytes.
///
/// A `.docx` is a zip archive; the body text lives in `word/document.xml` as
/// `<w:t>` runs. This walks those runs rather than stripping tags with a regex,
/// because a regex over XML silently concatenates words across element
/// boundaries — "ReactPostgreSQL" — and a claim extractor reading that would
/// produce skills nobody wrote.
ExtractedText extractDocxText(List<int> bytes) {
  try {
    final archive = ZipDecoder().decodeBytes(bytes);

    ArchiveFile? entry;
    for (final file in archive.files) {
      if (file.name == 'word/document.xml') {
        entry = file;
        break;
      }
    }

    if (entry == null) {
      return const ExtractedText.failure(
        'This file is a zip archive but has no word/document.xml inside, so it '
        'is not a Word document. If it was renamed from another format, attach '
        'the original instead.',
      );
    }

    final xml = XmlDocument.parse(utf8.decode(entry.content as List<int>));
    final buffer = StringBuffer();

    // Walk in document order so paragraphs come out in the order they were
    // written. `w:t` is a text run; `w:tab` and `w:br` are the separators that
    // would otherwise vanish and run two lines together.
    for (final node in xml.descendants.whereType<XmlElement>()) {
      switch (node.name.local) {
        case 't':
          buffer.write(node.innerText);
        case 'tab':
          buffer.write('\t');
        case 'br':
          buffer.write('\n');
        case 'p':
          // Closing a paragraph is what makes bullet lists survive as lines,
          // which is what the claim extractor splits on.
          buffer.write('\n');
      }
    }

    final cleaned = _tidy(buffer.toString());
    if (cleaned.isEmpty) {
      return const ExtractedText.failure(
        'This Word document opened correctly but contains no body text.',
      );
    }
    return ExtractedText.success(cleaned);
  } catch (error) {
    return ExtractedText.failure(
      'This .docx could not be read: $error',
    );
  }
}

/// Normalises whitespace without deleting structure.
///
/// Collapses runs of blank lines and trims trailing spaces, but keeps single
/// newlines: the claim extractor treats a line as a candidate assertion, so
/// flattening the document to one paragraph would destroy the only structure it
/// has to work with.
String _tidy(String raw) {
  final lines = raw
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .split('\n')
      .map((line) => line.replaceAll(RegExp(r'[ \t ]+'), ' ').trim());

  final out = <String>[];
  for (final line in lines) {
    // At most one blank line in a row — enough to keep sections apart, not
    // enough to leave page-break gaps that read as missing content.
    if (line.isEmpty && (out.isEmpty || out.last.isEmpty)) continue;
    out.add(line);
  }

  return out.join('\n').trim();
}
