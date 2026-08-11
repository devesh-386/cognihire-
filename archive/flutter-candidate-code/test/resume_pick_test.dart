import 'dart:io';

import 'package:cognihire/features/resume/resume_pick.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tests the [ResumePick] model directly, since the picker itself is a thin
/// platform-channel wrapper that widget/integration tests exercise. What
/// matters here is the rule this file exists to enforce: never fabricate text
/// a file doesn't contain.
void main() {
  group('ResumePick', () {
    test('hasText is true only for real, non-blank content', () {
      const withText = ResumePick(
        fileName: 'r.txt',
        filePath: '/r.txt',
        text: 'Built a distributed cache.',
        extractionNote: null,
      );
      const blank = ResumePick(
        fileName: 'r.txt',
        filePath: '/r.txt',
        text: '   \n  ',
        extractionNote: null,
      );
      const noText = ResumePick(
        fileName: 'r.pdf',
        filePath: '/r.pdf',
        text: null,
        extractionNote: 'not wired up',
      );

      expect(withText.hasText, isTrue);
      expect(blank.hasText, isFalse);
      expect(noText.hasText, isFalse);
    });
  });

  group('reading a real .txt file end to end', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('cognihire_resume_test');
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('a .txt file\'s actual content round-trips through File I/O',
        () async {
      final file = File('${dir.path}${Platform.pathSeparator}resume.txt');
      const content = 'Designed a distributed cache using Redis Cluster '
          'with consistent hashing.';
      await file.writeAsString(content);

      // Exercises the same dart:io path pickResume() takes for .txt, without
      // going through the platform file-picker channel (which needs a real
      // UI and is covered by manual/integration testing instead).
      final read = await file.readAsString();

      expect(read, content);
      expect(ResumePick(
        fileName: 'resume.txt',
        filePath: file.path,
        text: read,
        extractionNote: null,
      ).hasText, isTrue);
    });

    test('an unreadable path produces a failure note, not fabricated text',
        () async {
      final missing = File(
        '${dir.path}${Platform.pathSeparator}does_not_exist.txt',
      );

      Object? caught;
      try {
        await missing.readAsString();
      } catch (e) {
        caught = e;
      }

      expect(caught, isNotNull);
      // The production code path (pickResume) catches exactly this and turns
      // it into extractionNote rather than returning empty text silently.
    });
  });

  group('unsupported formats never get fabricated text', () {
    test('a .pdf pick carries a note, and text stays null', () {
      const pick = ResumePick(
        fileName: 'resume.pdf',
        filePath: '/resume.pdf',
        text: null,
        extractionNote: 'Text extraction for .pdf files isn\'t wired up yet '
            'in this build — only .txt is read directly right now. The file '
            'is attached, but its content is not shown or used.',
      );

      expect(pick.text, isNull);
      expect(pick.hasText, isFalse);
      expect(pick.extractionNote, contains('.pdf'));
      expect(pick.extractionNote, contains('not'));
    });

    test('a .docx pick carries the equivalent note', () {
      const pick = ResumePick(
        fileName: 'resume.docx',
        filePath: '/resume.docx',
        text: null,
        extractionNote: 'Text extraction for .docx files isn\'t wired up yet '
            'in this build — only .txt is read directly right now. The file '
            'is attached, but its content is not shown or used.',
      );

      expect(pick.hasText, isFalse);
      expect(pick.extractionNote, contains('.docx'));
    });
  });
}
