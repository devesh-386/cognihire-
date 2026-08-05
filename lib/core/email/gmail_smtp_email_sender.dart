/// Sends real email through Gmail's SMTP server, authenticated with an App
/// Password rather than the account's real password.
///
/// ## The security caveat, stated rather than hidden
///
/// This is a client app with no backend. The App Password lives in this
/// process's memory (supplied via `--dart-define`, never committed to
/// source) for as long as the app runs, which means it is extractable by
/// anyone who can inspect this build's memory or network traffic. That is an
/// accepted, informed risk for a demo running on the account holder's own
/// machine — not something to ship to a public app store. The fix, when this
/// matters, is a backend that holds the credential and relays sends; nothing
/// about [EmailSender]'s shape needs to change for that swap.
library;

import 'package:mailer/mailer.dart' as mailer;
import 'package:mailer/smtp_server.dart';

import 'email_sender.dart';

class GmailSmtpEmailSender implements EmailSender {
  GmailSmtpEmailSender({required this.address, required this.appPassword});

  final String address;
  final String appPassword;

  @override
  Future<EmailSendResult> send({
    required String to,
    required String subject,
    required String body,
  }) async {
    final server = gmail(address, appPassword);
    final message = mailer.Message()
      ..from = mailer.Address(address, 'CogniHire')
      ..recipients.add(to)
      ..subject = subject
      ..text = body;

    try {
      await mailer.send(message, server);
      return const EmailSendResult.sent();
    } on mailer.MailerException catch (e) {
      final problems = e.problems.map((p) => '${p.code}: ${p.msg}').join('; ');
      return EmailSendResult.failed(
        problems.isEmpty ? '$e' : problems,
      );
    } catch (e) {
      return EmailSendResult.failed('$e');
    }
  }
}
