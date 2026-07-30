/// A single observed change to the candidate's answer or code buffer.
///
/// Raw observation only. Nothing here interprets intent — that separation is
/// deliberate and load-bearing, see [ProcessTelemetry].
class EditEvent {
  const EditEvent({
    required this.at,
    required this.lengthBefore,
    required this.lengthAfter,
    required this.kind,
  });

  final DateTime at;
  final int lengthBefore;
  final int lengthAfter;
  final EditKind kind;

  int get delta => lengthAfter - lengthBefore;
  bool get isInsertion => delta > 0;
  bool get isDeletion => delta < 0;
}

enum EditKind {
  /// Ordinary typing — one or a few characters at a time.
  typing,

  /// Content arrived in a single step far larger than typing can account for.
  /// This means "arrived at once", NOT "was copied from elsewhere" and
  /// certainly not "was cheated". A candidate re-indenting a block, an IDE
  /// autocomplete, or a template expansion all land here.
  bulkInsert,

  /// A deletion large enough to be a rewrite rather than a correction.
  bulkDelete,
}
