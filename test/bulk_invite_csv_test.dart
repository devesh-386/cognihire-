import 'package:cognihire/core/invitations/bulk_invite_csv.dart';
import 'package:cognihire/core/invitations/invitation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseBulkInviteCsv', () {
    test('parses plain rows with no header', () {
      final result = parseBulkInviteCsv(
        'Jordan Rivera,jordan@example.com\nAlicia Kim,alicia@example.com',
      );
      expect(result.errors, isEmpty);
      expect(result.rows, hasLength(2));
      expect(result.rows[0].name, 'Jordan Rivera');
      expect(result.rows[0].email, 'jordan@example.com');
      expect(result.rows[1].name, 'Alicia Kim');
    });

    test('detects and skips a header row', () {
      final result = parseBulkInviteCsv(
        'Name,Email\nJordan Rivera,jordan@example.com',
      );
      expect(result.errors, isEmpty);
      expect(result.rows, hasLength(1));
      expect(result.rows.single.name, 'Jordan Rivera');
    });

    test('handles quoted fields with embedded commas', () {
      final result = parseBulkInviteCsv(
        '"Rivera, Jordan",jordan@example.com',
      );
      expect(result.rows.single.name, 'Rivera, Jordan');
    });

    test('reports a row with no name', () {
      final result = parseBulkInviteCsv(',jordan@example.com');
      expect(result.rows, isEmpty);
      expect(result.errors, hasLength(1));
      expect(result.errors.single.reason, contains('name'));
      expect(result.errors.single.lineNumber, 1);
    });

    test('reports a row with no email', () {
      final result = parseBulkInviteCsv('Jordan Rivera');
      expect(result.rows, isEmpty);
      expect(result.errors, hasLength(1));
      expect(result.errors.single.reason, contains('Jordan Rivera'));
    });

    test('reports a malformed email without crashing', () {
      final result = parseBulkInviteCsv('Jordan Rivera,not-an-email');
      expect(result.rows, isEmpty);
      expect(result.errors.single.reason, contains('not-an-email'));
    });

    test('skips blank lines rather than reporting them as errors', () {
      final result = parseBulkInviteCsv(
        'Jordan Rivera,jordan@example.com\n\nAlicia Kim,alicia@example.com',
      );
      expect(result.rows, hasLength(2));
      expect(result.errors, isEmpty);
    });

    test('mixed valid and invalid rows: every row is accounted for', () {
      final result = parseBulkInviteCsv(
        'Name,Email\n'
        'Jordan Rivera,jordan@example.com\n'
        'Broken Row\n'
        'Alicia Kim,alicia@example.com\n'
        'Bad Email,nope',
      );
      expect(result.rows, hasLength(2));
      expect(result.errors, hasLength(2));
      // Line numbers count the header, matching what HR sees in a spreadsheet.
      expect(result.errors[0].lineNumber, 3);
      expect(result.errors[1].lineNumber, 5);
    });

    test('an empty file parses to nothing, cleanly', () {
      final result = parseBulkInviteCsv('');
      expect(result.isEmpty, isTrue);
    });
  });

  group('buildInvitationsFromRows', () {
    test('builds one invitation per row, all bound to the given role', () {
      const rows = [
        BulkInviteRow(name: 'Jordan Rivera', email: 'jordan@example.com'),
        BulkInviteRow(name: 'Alicia Kim', email: 'alicia@example.com'),
      ];
      final invitations = buildInvitationsFromRows(rows, 'role-backend');

      expect(invitations, hasLength(2));
      expect(invitations[0].candidateName, 'Jordan Rivera');
      expect(invitations[0].candidateEmail, 'jordan@example.com');
      expect(invitations.every((i) => i.roleId == 'role-backend'), isTrue);
      expect(invitations.every((i) => i.status == InvitationStatus.pending),
          isTrue);
    });

    test('every code in the batch is distinct', () {
      final rows = [
        for (var i = 0; i < 50; i++)
          BulkInviteRow(name: 'Candidate $i', email: 'c$i@example.com'),
      ];
      final invitations = buildInvitationsFromRows(rows, 'role-backend');
      final codes = invitations.map((i) => i.code).toSet();
      expect(codes, hasLength(50));
    });

    test('an empty row list builds nothing', () {
      expect(buildInvitationsFromRows(const [], 'role-backend'), isEmpty);
    });
  });
}
