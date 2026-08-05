/// Composes the invitation email's subject and body — a pure function,
/// deliberately separated from anything that sends. Nothing about the wording
/// here is fabricated: it states the role, the code, and what to do with it,
/// and nothing else about the candidate or process.
library;

import 'invitation.dart';

class ComposedEmail {
  const ComposedEmail({required this.subject, required this.body});

  final String subject;
  final String body;
}

/// [roleTitle] is passed rather than resolved from [invitation.roleId] here,
/// because a role can be edited or deleted after an invitation exists — the
/// caller resolves it (or states it is gone) and this function stays a pure
/// string transform with no store dependency.
ComposedEmail composeInvitationEmail({
  required Invitation invitation,
  required String roleTitle,
  String? senderName,
}) {
  final subject = 'Your interview invitation — $roleTitle';

  final greeting = 'Hi ${invitation.candidateName},';
  final from = senderName == null || senderName.trim().isEmpty
      ? ''
      : '\n\nInvited by $senderName.';

  final body = '$greeting\n\n'
      'You have been invited to interview for the "$roleTitle" role on '
      'CogniHire.\n\n'
      'Your invitation code is:\n\n'
      '    ${invitation.code}\n\n'
      'Open CogniHire, choose "Continue as Candidate", and enter this code '
      'to begin.$from';

  return ComposedEmail(subject: subject, body: body);
}
