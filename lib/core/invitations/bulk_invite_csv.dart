/// Parsing HR's CSV of candidates into rows ready to invite.
///
/// ## What "at scale" actually needs
///
/// One invitation at a time works for a handful of candidates; it does not
/// work for the hiring event this was asked for — dozens of names in one
/// file. This is the parsing half of that: turn a CSV (name, email columns,
/// header optional) into validated rows, or a specific reason why a row could
/// not be used. Nothing here sends anything; see `bulk_invite_result.dart` and
/// the email sender for what happens to a validated row next.
///
/// ## Every row is reported, never silently dropped
///
/// A row with a name but no email, or an email that is not shaped like one,
/// is not skipped — it comes back as a [BulkInviteRowError] so HR sees
/// exactly which rows in their file need fixing, the same "report the fault,
/// never hide it" rule the rest of this codebase's parsers follow.
library;

import 'package:csv/csv.dart';

import 'invitation.dart';

/// One candidate ready to be invited.
class BulkInviteRow {
  const BulkInviteRow({required this.name, required this.email});

  final String name;
  final String email;
}

/// A row from the file that could not be turned into a [BulkInviteRow].
class BulkInviteRowError {
  const BulkInviteRowError({required this.lineNumber, required this.reason});

  /// 1-indexed, counting the header row if one was detected — matches what a
  /// person sees if they open the file in a spreadsheet app.
  final int lineNumber;
  final String reason;
}

class BulkInviteParseResult {
  const BulkInviteParseResult({required this.rows, required this.errors});

  final List<BulkInviteRow> rows;
  final List<BulkInviteRowError> errors;

  bool get hasErrors => errors.isNotEmpty;
  bool get isEmpty => rows.isEmpty && errors.isEmpty;
}

// Deliberately simple, not RFC 5322: this rejects the shape of a mistyped
// email ("alice.example.com", "alice@") without pretending to validate every
// address the standard technically allows — that's the reviewer's job at
// send time, not this parser's.
final _emailShape = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

/// Parses [csvText] into candidate rows.
///
/// A first row is treated as a header (and skipped) if its first cell reads
/// like a label — "name", "candidate", etc. — rather than assuming position;
/// a file with no header starts contributing rows from line one.
BulkInviteParseResult parseBulkInviteCsv(String csvText) {
  final table = const CsvToListConverter(
    shouldParseNumbers: false,
  ).convert(csvText, eol: '\n');

  final rows = <BulkInviteRow>[];
  final errors = <BulkInviteRowError>[];

  var startIndex = 0;
  if (table.isNotEmpty) {
    final firstCell = table.first.isEmpty ? '' : '${table.first.first}';
    if (_looksLikeHeader(firstCell)) startIndex = 1;
  }

  for (var i = startIndex; i < table.length; i++) {
    final lineNumber = i + 1;
    final record = table[i];
    if (record.isEmpty || record.every((c) => '$c'.trim().isEmpty)) continue;

    final name = record.isNotEmpty ? '${record[0]}'.trim() : '';
    final email = record.length > 1 ? '${record[1]}'.trim() : '';

    if (name.isEmpty) {
      errors.add(BulkInviteRowError(
        lineNumber: lineNumber,
        reason: 'No candidate name in the first column.',
      ));
      continue;
    }
    if (email.isEmpty) {
      errors.add(BulkInviteRowError(
        lineNumber: lineNumber,
        reason: 'No email in the second column for "$name".',
      ));
      continue;
    }
    if (!_emailShape.hasMatch(email)) {
      errors.add(BulkInviteRowError(
        lineNumber: lineNumber,
        reason: '"$email" does not look like an email address.',
      ));
      continue;
    }

    rows.add(BulkInviteRow(name: name, email: email));
  }

  return BulkInviteParseResult(rows: rows, errors: errors);
}

bool _looksLikeHeader(String firstCell) {
  final needle = firstCell.trim().toLowerCase();
  return needle == 'name' || needle == 'candidate' || needle == 'candidate name';
}

/// Turns validated CSV rows into ready-to-save [Invitation]s, all bound to
/// [roleId]. Pulled out of the review dialog so the actual construction logic
/// — codes salted by index so a batch can never collide with itself, see
/// [generateInvitationCode] — is tested directly rather than only through a
/// widget that owns a file picker.
List<Invitation> buildInvitationsFromRows(
  List<BulkInviteRow> rows,
  String roleId,
) {
  final now = DateTime.now();
  return [
    for (var i = 0; i < rows.length; i++)
      Invitation(
        id: 'inv-${now.microsecondsSinceEpoch}-$i',
        candidateName: rows[i].name,
        candidateEmail: rows[i].email,
        roleId: roleId,
        code: generateInvitationCode(salt: i),
        createdAt: now,
        expiresAt: now.add(defaultInvitationValidity),
      ),
  ];
}
