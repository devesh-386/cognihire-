import 'package:cognihire/core/telemetry/keystroke_event.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final start = DateTime(2026, 7, 28, 10, 0, 0);

  KeystrokeEvent evt({
    int atMs = 0,
    KeycodeClass cls = KeycodeClass.alpha,
    KeystrokeAction action = KeystrokeAction.insert,
    int cursor = 0,
    int selection = 0,
    int before = 0,
    int after = 1,
  }) =>
      KeystrokeEvent(
        at: start.add(Duration(milliseconds: atMs)),
        keycodeClass: cls,
        action: action,
        cursorPosition: cursor,
        selectionLength: selection,
        lengthBefore: before,
        lengthAfter: after,
      );

  group('KeycodeClass.ofCharacter — classification, never retention', () {
    test('letters classify as alpha, in any script', () {
      expect(KeycodeClass.ofCharacter('a'), KeycodeClass.alpha);
      expect(KeycodeClass.ofCharacter('Z'), KeycodeClass.alpha);
      expect(KeycodeClass.ofCharacter('é'), KeycodeClass.alpha);
      expect(KeycodeClass.ofCharacter('क'), KeycodeClass.alpha);
    });

    test('digits classify as digit', () {
      for (final d in '0123456789'.split('')) {
        expect(KeycodeClass.ofCharacter(d), KeycodeClass.digit, reason: d);
      }
    });

    test('whitespace classifies as whitespace', () {
      expect(KeycodeClass.ofCharacter(' '), KeycodeClass.whitespace);
      expect(KeycodeClass.ofCharacter('\t'), KeycodeClass.whitespace);
      expect(KeycodeClass.ofCharacter('\n'), KeycodeClass.whitespace);
    });

    test('printable non-alphanumerics classify as symbol', () {
      for (final s in r'{}()[];:,.<>/?|\+-*=&^%$#@!~`'.split('')) {
        expect(KeycodeClass.ofCharacter(s), KeycodeClass.symbol, reason: s);
      }
    });

    test('an empty or multi-character string is unknown, never a guess', () {
      expect(KeycodeClass.ofCharacter(''), KeycodeClass.unknown);
      expect(KeycodeClass.ofCharacter('ab'), KeycodeClass.unknown);
    });
  });

  group('privacy invariant — the log cannot become a password logger', () {
    test('the serialised form carries no character, text or content field', () {
      final json = evt(cls: KeycodeClass.alpha).toJson();
      const forbidden = {
        'char',
        'character',
        'text',
        'content',
        'value',
        'key',
        'keyLabel',
      };
      for (final k in json.keys) {
        expect(forbidden.contains(k), isFalse,
            reason: 'serialised keystroke must not carry "$k"');
      }
    });

    test('the serialised form is exactly the seven agreed fields', () {
      expect(
        evt().toJson().keys.toSet(),
        {
          't',
          'class',
          'action',
          'cursor',
          'selection',
          'lenBefore',
          'lenAfter',
        },
      );
    });

    test('classification discards the character it was given', () {
      // ofCharacter returns an enum drawn from a fixed set. The input cannot be
      // recovered from it: two different letters map to the identical value.
      expect(KeycodeClass.ofCharacter('q'), KeycodeClass.ofCharacter('z'));
      expect(KeycodeClass.ofCharacter('7'), KeycodeClass.ofCharacter('3'));
      // And the returned category is one of the fixed enum members, carrying no
      // trace of which character produced it.
      expect(KeycodeClass.values.contains(KeycodeClass.ofCharacter('q')),
          isTrue);
    });
  });

  group('KeystrokeEvent', () {
    test('delta is derived, not stored', () {
      expect(evt(before: 10, after: 14).delta, 4);
      expect(evt(before: 14, after: 10).delta, -4);
    });

    test('round-trips through JSON without loss', () {
      final e = evt(
        atMs: 1234,
        cls: KeycodeClass.symbol,
        action: KeystrokeAction.delete,
        cursor: 7,
        selection: 3,
        before: 20,
        after: 17,
      );
      final back = KeystrokeEvent.fromJson(e.toJson());
      expect(back.at, e.at);
      expect(back.keycodeClass, e.keycodeClass);
      expect(back.action, e.action);
      expect(back.cursorPosition, e.cursorPosition);
      expect(back.selectionLength, e.selectionLength);
      expect(back.lengthBefore, e.lengthBefore);
      expect(back.lengthAfter, e.lengthAfter);
    });

    test('an unrecognised class or action deserialises to unknown, not a throw',
        () {
      final json = evt().toJson()
        ..['class'] = 'nonsense'
        ..['action'] = 'nonsense';
      final back = KeystrokeEvent.fromJson(json);
      expect(back.keycodeClass, KeycodeClass.unknown);
      expect(back.action, KeystrokeAction.unknown);
    });
  });

  group('KeystrokeLog', () {
    test('starts empty and exposes an unmodifiable view', () {
      final log = KeystrokeLog();
      expect(log.events, isEmpty);
      expect(() => log.events.add(evt()), throwsUnsupportedError);
    });

    test('records in order and reset clears', () {
      final log = KeystrokeLog();
      log.add(evt(atMs: 0));
      log.add(evt(atMs: 50));
      expect(log.events.length, 2);
      expect(log.events.first.at.isBefore(log.events.last.at), isTrue);
      log.reset();
      expect(log.events, isEmpty);
    });

    test('capacity is bounded so a long session cannot exhaust memory', () {
      final log = KeystrokeLog(maxEvents: 3);
      for (var i = 0; i < 10; i++) {
        log.add(evt(atMs: i * 10));
      }
      expect(log.events.length, 3);
      // The most recent are kept; the oldest are dropped.
      expect(log.events.last.at, start.add(const Duration(milliseconds: 90)));
      expect(log.droppedCount, 7);
    });

    test('serialises to JSONL, one event per line', () {
      final log = KeystrokeLog();
      log.add(evt(atMs: 0));
      log.add(evt(atMs: 10));
      final lines = log.toJsonl().split('\n');
      expect(lines.length, 2);
      expect(KeystrokeLog.fromJsonl(log.toJsonl()).events.length, 2);
    });

    test('an empty log serialises to an empty string, not a blank line', () {
      expect(KeystrokeLog().toJsonl(), '');
      expect(KeystrokeLog.fromJsonl('').events, isEmpty);
    });
  });
}
