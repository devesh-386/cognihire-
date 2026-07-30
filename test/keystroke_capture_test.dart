import 'package:cognihire/core/telemetry/keystroke_capture.dart';
import 'package:cognihire/core/telemetry/keystroke_event.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final t0 = DateTime(2026, 7, 28, 12, 0, 0);

  group('single-character insertion', () {
    test('a typed letter is an alpha insert', () {
      final cap = KeystrokeCapture();
      final e = cap.observe(
        oldText: 'ab',
        newText: 'abc',
        cursor: 3,
        selectionLength: 0,
        at: t0,
      );
      expect(e, isNotNull);
      expect(e!.action, KeystrokeAction.insert);
      expect(e.keycodeClass, KeycodeClass.alpha);
      expect(e.lengthBefore, 2);
      expect(e.lengthAfter, 3);
      expect(e.cursorPosition, 3);
    });

    test('a typed digit is a digit insert', () {
      final e = KeystrokeCapture().observe(
        oldText: 'x', newText: 'x7', cursor: 2, selectionLength: 0, at: t0);
      expect(e!.keycodeClass, KeycodeClass.digit);
    });

    test('a space is a whitespace insert', () {
      final e = KeystrokeCapture().observe(
        oldText: 'a', newText: 'a ', cursor: 2, selectionLength: 0, at: t0);
      expect(e!.keycodeClass, KeycodeClass.whitespace);
    });

    test('a symbol is a symbol insert', () {
      final e = KeystrokeCapture().observe(
        oldText: 'f', newText: 'f(', cursor: 2, selectionLength: 0, at: t0);
      expect(e!.keycodeClass, KeycodeClass.symbol);
    });
  });

  group('deletion', () {
    test('a single backspace is a delete', () {
      final e = KeystrokeCapture().observe(
        oldText: 'abc', newText: 'ab', cursor: 2, selectionLength: 0, at: t0);
      expect(e!.action, KeystrokeAction.delete);
      expect(e.keycodeClass, KeycodeClass.delete);
      expect(e.delta, -1);
    });

    test('deleting a selection is one delete event, not many', () {
      final e = KeystrokeCapture().observe(
        oldText: 'hello world',
        newText: 'hello',
        cursor: 5,
        selectionLength: 0,
        at: t0,
      );
      expect(e!.action, KeystrokeAction.delete);
      expect(e.delta, -6);
    });
  });

  group('paste / bulk insertion', () {
    test('more than one character inserted has unknown class', () {
      final e = KeystrokeCapture().observe(
        oldText: '',
        newText: 'def foo():',
        cursor: 10,
        selectionLength: 0,
        at: t0,
      );
      expect(e!.action, KeystrokeAction.insert);
      // We never guess a class for a multi-character change — it could be a
      // paste, an autocomplete, or an IME commit.
      expect(e.keycodeClass, KeycodeClass.unknown);
      expect(e.delta, 10);
    });
  });

  group('navigation and selection without edit', () {
    test('cursor movement with no length change is a navigate', () {
      final cap = KeystrokeCapture();
      final e = cap.observe(
        oldText: 'abcd',
        newText: 'abcd',
        cursor: 2,
        selectionLength: 0,
        at: t0,
      );
      expect(e!.action, KeystrokeAction.navigate);
      expect(e.keycodeClass, KeycodeClass.nav);
      expect(e.delta, 0);
    });

    test('a selection with no length change is a select', () {
      final e = KeystrokeCapture().observe(
        oldText: 'abcd',
        newText: 'abcd',
        cursor: 4,
        selectionLength: 3,
        at: t0,
      );
      expect(e!.action, KeystrokeAction.select);
      expect(e.selectionLength, 3);
    });

    test('an identical unchanged snapshot produces nothing', () {
      final cap = KeystrokeCapture();
      // First snapshot navigates (cursor 0), the identical second is a no-op.
      cap.observe(
          oldText: 'abcd', newText: 'abcd', cursor: 0, selectionLength: 0, at: t0);
      final e = cap.observe(
          oldText: 'abcd',
          newText: 'abcd',
          cursor: 0,
          selectionLength: 0,
          at: t0.add(const Duration(seconds: 1)));
      expect(e, isNull);
    });
  });

  group('captureFrom convenience over prior state', () {
    test('classifies successive edits against remembered state', () {
      final cap = KeystrokeCapture();
      final log = KeystrokeLog();

      for (final entry in [
        ('a', 1, 0),
        ('ab', 2, 0),
        ('ab3', 3, 0),
        ('ab', 2, 0), // backspace
      ]) {
        final e = cap.captureFrom(
          newText: entry.$1,
          cursor: entry.$2,
          selectionLength: entry.$3,
          at: t0,
        );
        if (e != null) log.add(e);
      }

      expect(log.events.map((e) => e.keycodeClass).toList(), [
        KeycodeClass.alpha,
        KeycodeClass.alpha,
        KeycodeClass.digit,
        KeycodeClass.delete,
      ]);
    });

    test('the very first observation is measured against empty text', () {
      final e = KeystrokeCapture().captureFrom(
          newText: 'h', cursor: 1, selectionLength: 0, at: t0);
      expect(e!.lengthBefore, 0);
      expect(e.action, KeystrokeAction.insert);
      expect(e.keycodeClass, KeycodeClass.alpha);
    });
  });
}
