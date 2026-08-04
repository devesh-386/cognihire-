/// Proves the PDF and DOCX extractors read real documents, and — the part that
/// actually matters — that they refuse rather than fabricate when they cannot.
///
/// The documents here are *built in the test* rather than checked in as
/// fixtures, so what is asserted is a genuine round trip: text goes into a real
/// PDF/zip container, and the extractor pulls that same text back out. A
/// checked-in binary fixture would prove the parser runs; this proves it reads.
library;

import 'dart:convert';
import 'dart:ui' show Rect;

import 'package:archive/archive.dart';
import 'package:cognihire/features/resume/resume_text_extraction.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

/// A real PDF containing [lines], drawn as actual text.
List<int> _pdfWith(List<String> lines) {
  final document = PdfDocument();
  final page = document.pages.add();
  final font = PdfStandardFont(PdfFontFamily.helvetica, 12);

  var y = 0.0;
  for (final line in lines) {
    page.graphics.drawString(
      line,
      font,
      bounds: Rect.fromLTWH(0, y, page.getClientSize().width, 20),
    );
    y += 20;
  }

  final bytes = document.saveSync();
  document.dispose();
  return bytes;
}

/// A minimal but structurally real .docx: a zip whose word/document.xml holds
/// `<w:t>` runs, which is exactly what Word writes.
List<int> _docxWith(List<String> paragraphs) {
  final body = paragraphs
      .map((p) => '<w:p><w:r><w:t>${const HtmlEscape().convert(p)}'
          '</w:t></w:r></w:p>')
      .join();

  final xml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<w:document xmlns:w="http://schemas.openxmlformats.org/'
      'wordprocessingml/2006/main"><w:body>$body</w:body></w:document>';

  final archive = Archive()
    ..addFile(ArchiveFile.string('word/document.xml', xml));
  return ZipEncoder().encode(archive);
}

void main() {
  group('PDF extraction', () {
    test('reads back the text the document actually contains', () {
      final bytes = _pdfWith([
        'Built and shipped a React dashboard used by 200+ staff.',
        'Optimised Postgres queries, cutting p95 latency by 60%.',
      ]);

      final result = extractPdfText(bytes);

      expect(result.succeeded, isTrue, reason: result.reason);
      expect(result.text, contains('React dashboard'));
      expect(result.text, contains('Postgres'));
      expect(result.reason, isNull);
    });

    test('a PDF with no text layer fails loudly instead of reading as empty',
        () {
      // A page with nothing drawn on it is the structural equivalent of a scan:
      // a valid PDF whose text extraction legitimately yields nothing.
      final document = PdfDocument();
      document.pages.add();
      final bytes = document.saveSync();
      document.dispose();

      final result = extractPdfText(bytes);

      expect(result.succeeded, isFalse);
      expect(result.text, isNull,
          reason: 'an empty string here would read downstream as "a resume '
              'containing nothing", which is a different claim');
      expect(result.reason, contains('no extractable text'));
      expect(result.reason, contains('OCR'));
    });

    test('bytes that are not a PDF are reported, not guessed at', () {
      final result = extractPdfText(utf8.encode('this is plainly not a pdf'));

      expect(result.succeeded, isFalse);
      expect(result.text, isNull);
      expect(result.reason, contains('could not be opened'));
    });
  });

  group('DOCX extraction', () {
    test('reads paragraphs back in document order', () {
      final bytes = _docxWith([
        'Led migration of CI pipeline to GitHub Actions.',
        'Mentored three junior engineers.',
      ]);

      final result = extractDocxText(bytes);

      expect(result.succeeded, isTrue, reason: result.reason);
      expect(result.text, contains('GitHub Actions'));
      expect(result.text, contains('Mentored three junior engineers'));
      expect(
        result.text!.indexOf('GitHub Actions'),
        lessThan(result.text!.indexOf('Mentored')),
        reason: 'order carries meaning in a resume',
      );
    });

    test('paragraphs stay on separate lines rather than running together', () {
      final bytes = _docxWith(['React', 'PostgreSQL']);

      final result = extractDocxText(bytes);

      expect(result.succeeded, isTrue);
      // The regex-over-XML shortcut this avoids would yield "ReactPostgreSQL",
      // and the claim extractor would then invent a skill nobody wrote.
      expect(result.text, isNot(contains('ReactPostgreSQL')));
      expect(result.text!.split('\n'), containsAll(['React', 'PostgreSQL']));
    });

    test('a zip with no word/document.xml is refused', () {
      final archive = Archive()
        ..addFile(ArchiveFile.string('hello.txt', 'not a word document'));
      final result = extractDocxText(ZipEncoder().encode(archive));

      expect(result.succeeded, isFalse);
      expect(result.reason, contains('word/document.xml'));
    });

    test('bytes that are not a zip are reported', () {
      final result = extractDocxText(utf8.encode('plain text, not a zip'));

      expect(result.succeeded, isFalse);
      expect(result.text, isNull);
    });
  });
}
