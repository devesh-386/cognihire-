import 'keystroke_event.dart';

/// Turns successive text-field snapshots into [KeystrokeEvent]s without ever
/// touching a key-event stream.
///
/// ## Why diff snapshots instead of listening for keys
///
/// A `RawKeyboardListener` only sees physical key presses. On a phone soft
/// keyboard, with autocomplete, or through an IME, that stream is empty or
/// wrong — exactly the platforms a candidate is most likely to use. Diffing the
/// controller's before/after state is the one approach that works everywhere,
/// and it has a second virtue: the character is classified and dropped inside
/// this pure function, so no widget ever holds content-bearing state.
///
/// ## What a diff can and cannot tell us
///
/// From two buffer snapshots we can recover the *net* change — how many
/// characters appeared or vanished, and where the caret ended up. When exactly
/// one character was inserted we can classify it. For anything larger — a paste,
/// an IME commit, an autocomplete expansion — we record the change as an insert
/// of [KeycodeClass.unknown] rather than inventing a class we cannot justify.
/// That honesty is the point: [ProcessTelemetry] already flags large insertions
/// as spans worth a follow-up question; this layer does not need to pretend it
/// saw them typed.
class KeystrokeCapture {
  KeystrokeCapture({String initialText = ''}) : _lastText = initialText;

  String _lastText;

  /// Classify the transition from [oldText] to [newText]. Returns null when
  /// nothing observable happened (an identical snapshot with no caret move).
  ///
  /// This form is stateless in [oldText]; prefer [captureFrom] to have the
  /// adapter remember prior text for you.
  KeystrokeEvent? observe({
    required String oldText,
    required String newText,
    required int cursor,
    required int selectionLength,
    required DateTime at,
  }) {
    final before = oldText.length;
    final after = newText.length;
    final delta = after - before;

    KeystrokeAction action;
    KeycodeClass cls;

    if (delta > 0) {
      action = KeystrokeAction.insert;
      // Only a single-character insertion can be classified; anything wider is
      // a paste / IME commit / autocomplete and stays honestly unknown.
      cls = delta == 1
          ? KeycodeClass.ofCharacter(_insertedChar(oldText, newText))
          : KeycodeClass.unknown;
    } else if (delta < 0) {
      action = KeystrokeAction.delete;
      cls = KeycodeClass.delete;
    } else {
      // No length change. Distinguish a selection from a bare caret move; an
      // identical snapshot with neither is not an event at all.
      if (selectionLength > 0) {
        action = KeystrokeAction.select;
        cls = KeycodeClass.nav;
      } else if (newText == oldText && _isRepeatOfLastCaret(cursor)) {
        return null;
      } else {
        action = KeystrokeAction.navigate;
        cls = KeycodeClass.nav;
      }
    }

    _lastCursor = cursor;
    return KeystrokeEvent(
      at: at,
      keycodeClass: cls,
      action: action,
      cursorPosition: cursor,
      selectionLength: selectionLength,
      lengthBefore: before,
      lengthAfter: after,
    );
  }

  /// Like [observe], but the adapter supplies [oldText] from the previous call.
  KeystrokeEvent? captureFrom({
    required String newText,
    required int cursor,
    required int selectionLength,
    required DateTime at,
  }) {
    final event = observe(
      oldText: _lastText,
      newText: newText,
      cursor: cursor,
      selectionLength: selectionLength,
      at: at,
    );
    _lastText = newText;
    return event;
  }

  int? _lastCursor;

  bool _isRepeatOfLastCaret(int cursor) => _lastCursor == cursor;

  /// The single character that [newText] has and [oldText] does not, found by
  /// walking in from both ends. Returns '' if it cannot be isolated (which sends
  /// the classifier to [KeycodeClass.unknown]).
  static String _insertedChar(String oldText, String newText) {
    if (newText.length - oldText.length != 1) return '';
    var i = 0;
    while (i < oldText.length && oldText[i] == newText[i]) {
      i++;
    }
    // i is now the index of the inserted character in newText.
    return i < newText.length ? newText[i] : '';
  }
}
