import 'package:cognihire/core/email/email_sender.dart';
import 'package:cognihire/core/invitations/invitation.dart';
import 'package:cognihire/core/invitations/invitation_email.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final invitation = Invitation(
    id: 'inv-1',
    candidateName: 'Jordan Rivera',
    candidateEmail: 'jordan@example.com',
    roleId: 'role-backend',
    code: 'ABC123',
    createdAt: DateTime(2026, 8, 1),
  );

  group('composeInvitationEmail', () {
    test('subject names the role', () {
      final email = composeInvitationEmail(
        invitation: invitation,
        roleTitle: 'Senior Backend Engineer',
      );
      expect(email.subject, contains('Senior Backend Engineer'));
    });

    test('body contains the candidate name and the real code', () {
      final email = composeInvitationEmail(
        invitation: invitation,
        roleTitle: 'Senior Backend Engineer',
      );
      expect(email.body, contains('Jordan Rivera'));
      expect(email.body, contains('ABC123'));
    });

    test('body names the sender when one is given', () {
      final email = composeInvitationEmail(
        invitation: invitation,
        roleTitle: 'Senior Backend Engineer',
        senderName: 'Priya Shah — Meridian Health',
      );
      expect(email.body, contains('Priya Shah — Meridian Health'));
    });

    test('body omits a sender line when none is given', () {
      final email = composeInvitationEmail(
        invitation: invitation,
        roleTitle: 'Senior Backend Engineer',
      );
      expect(email.body, isNot(contains('Invited by')));
    });
  });

  group('NullEmailSender', () {
    test('fails honestly, with an actionable reason', () async {
      const sender = NullEmailSender();
      final result = await sender.send(
        to: 'jordan@example.com',
        subject: 'x',
        body: 'y',
      );
      expect(result.success, isFalse);
      expect(result.error, contains('not configured'));
      expect(result.error, contains('GMAIL_ADDRESS'));
    });
  });
}
