/// Keystroke-level capture — the substrate the typing-dynamics and
/// editing-behaviour feature groups are computed from.
///
/// ## The privacy constraint, stated as a design rule
///
/// A keystroke log that stores characters is a password logger. There is no
/// version of this project in which that is acceptable, and no configuration
/// flag that turns it on. So the character never enters the data model at all:
/// [KeycodeClass.ofCharacter] takes a character, returns a category, and drops
/// it. [KeystrokeEvent] has no field capable of holding text, which means the
/// guarantee is structural rather than procedural — it cannot be forgotten by a
/// later edit without deleting a test that says so.
///
/// What survives is the *shape* of typing: when a key landed, what kind of key
/// it was, where the cursor was, and how the buffer length changed. That is
/// enough for inter-key interval statistics, burst and pause structure,
/// backspace rate, and cursor-travel behaviour. It is not enough to recover
/// what was written.
///
/// ## Relationship to ProcessTelemetry
///
/// [ProcessTelemetry] records buffer *lengths* and classifies edits into
/// typing / bulk-insert / bulk-delete. That is a coarser view, it already has
/// two call sites, and it is not being replaced. This is the finer-grained
/// layer underneath it; the two are recorded together and neither derives from
/// the other.
library;

import 'dart:convert';

/// The category of key that produced an event. Deliberately coarse — finer
/// categories would start to leak content.
enum KeycodeClass {
  alpha,
  digit,
  symbol,
  whitespace,

  /// Arrow keys, Home/End, Page Up/Down — cursor movement without edit.
  nav,

  /// Backspace and Delete.
  delete,

  /// Shift, Ctrl, Alt, Meta held or pressed alone.
  modifier,

  /// Not classifiable. Recorded honestly rather than guessed at — an unknown
  /// class is a usable signal, a wrong one is not.
  unknown;

  static final RegExp _whitespace = RegExp(r'^\s$');
  static final RegExp _digit = RegExp(r'^[0-9]$');
  static final RegExp _letter = RegExp(r'^\p{L}$', unicode: true);

  /// Classify a single character and discard it.
  ///
  /// Anything that is not exactly one UTF-16 code unit — an empty string, a
  /// multi-character paste, an emoji — is [unknown]. Guessing would be worse
  /// than admitting the gap.
  static KeycodeClass ofCharacter(String ch) {
    if (ch.length != 1) return unknown;
    if (_whitespace.hasMatch(ch)) return whitespace;
    if (_digit.hasMatch(ch)) return digit;
    if (_letter.hasMatch(ch)) return alpha;
    // Any remaining printable character is a symbol; control characters are
    // not classifiable.
    if (ch.codeUnitAt(0) > 32) return symbol;
    return unknown;
  }

  static KeycodeClass _parse(Object? name) => KeycodeClass.values.firstWhere(
        (v) => v.name == name,
        orElse: () => KeycodeClass.unknown,
      );
}

/// What the keystroke did to the buffer.
enum KeystrokeAction {
  insert,
  delete,

  /// Cursor moved, buffer unchanged.
  navigate,

  /// Selection changed, buffer unchanged.
  select,

  unknown;

  static KeystrokeAction _parse(Object? name) =>
      KeystrokeAction.values.firstWhere(
        (v) => v.name == name,
        orElse: () => KeystrokeAction.unknown,
      );
}

/// One observed keystroke. Seven fields, none of which is content.
class KeystrokeEvent {
  const KeystrokeEvent({
    required this.at,
    required this.keycodeClass,
    required this.action,
    required this.cursorPosition,
    required this.selectionLength,
    required this.lengthBefore,
    required this.lengthAfter,
  });

  final DateTime at;
  final KeycodeClass keycodeClass;
  final KeystrokeAction action;

  /// Caret offset after the event.
  final int cursorPosition;

  /// Length of the selection after the event; 0 when the caret is collapsed.
  final int selectionLength;

  final int lengthBefore;
  final int lengthAfter;

  /// Derived, never stored — one source of truth for the change in size.
  int get delta => lengthAfter - lengthBefore;

  Map<String, Object?> toJson() => {
        't': at.toIso8601String(),
        'class': keycodeClass.name,
        'action': action.name,
        'cursor': cursorPosition,
        'selection': selectionLength,
        'lenBefore': lengthBefore,
        'lenAfter': lengthAfter,
      };

  factory KeystrokeEvent.fromJson(Map<String, Object?> json) => KeystrokeEvent(
        at: DateTime.parse(json['t']! as String),
        keycodeClass: KeycodeClass._parse(json['class']),
        action: KeystrokeAction._parse(json['action']),
        cursorPosition: (json['cursor'] as num?)?.toInt() ?? 0,
        selectionLength: (json['selection'] as num?)?.toInt() ?? 0,
        lengthBefore: (json['lenBefore'] as num?)?.toInt() ?? 0,
        lengthAfter: (json['lenAfter'] as num?)?.toInt() ?? 0,
      );
}

/// An append-only, bounded log of keystrokes for a single task.
///
/// The bound matters: a long session at speed produces tens of thousands of
/// events, and an unbounded list on a phone is a crash. When the cap is hit the
/// oldest events are dropped and counted, so a consumer can tell the difference
/// between "the candidate typed little" and "we stopped recording".
class KeystrokeLog {
  KeystrokeLog({this.maxEvents = 50000})
      : assert(maxEvents > 0, 'maxEvents must be positive');

  final int maxEvents;
  final List<KeystrokeEvent> _events = [];

  int _dropped = 0;

  /// How many events were discarded to stay within [maxEvents].
  /// Non-zero means the log is truncated and features derived from the full
  /// history are not trustworthy.
  int get droppedCount => _dropped;

  List<KeystrokeEvent> get events => List.unmodifiable(_events);

  void add(KeystrokeEvent event) {
    _events.add(event);
    if (_events.length > maxEvents) {
      final overflow = _events.length - maxEvents;
      _events.removeRange(0, overflow);
      _dropped += overflow;
    }
  }

  void reset() {
    _events.clear();
    _dropped = 0;
  }

  /// One JSON object per line. An empty log is an empty string — not a blank
  /// line, which would parse as one malformed record.
  String toJsonl() => _events.map((e) => _encode(e.toJson())).join('\n');

  static KeystrokeLog fromJsonl(String jsonl, {int maxEvents = 50000}) {
    final log = KeystrokeLog(maxEvents: maxEvents);
    for (final line in jsonl.split('\n')) {
      if (line.trim().isEmpty) continue;
      log.add(KeystrokeEvent.fromJson(
          _decode(line).cast<String, Object?>()));
    }
    return log;
  }

  static String _encode(Map<String, Object?> m) =>
      const JsonEncoder().convert(m);

  static Map<dynamic, dynamic> _decode(String s) =>
      const JsonDecoder().convert(s) as Map<dynamic, dynamic>;
}
