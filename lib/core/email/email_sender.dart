/// Sending an email, abstracted behind one interface.
///
/// ## Why this is an interface at all
///
/// The real implementation ([GmailSmtpEmailSender]) needs a Gmail address and
/// an App Password to exist, and this app has nowhere to safely hold that
/// secret yet — it is a client with no backend. Rather than make the
/// invitations feature depend on that secret being present, every caller
/// depends on this interface; [NullEmailSender] answers honestly ("not
/// configured") when it isn't, and the day a backend exists to hold the
/// credential safely, only `main.dart`'s wiring needs to change.
library;

/// What sending one email came back as.
class EmailSendResult {
  const EmailSendResult.sent() : success = true, error = null;
  const EmailSendResult.failed(String reason) : success = false, error = reason;

  final bool success;

  /// Non-null exactly when [success] is false — why it did not go out. Never
  /// swallowed: a failed send that looked like a success would leave a
  /// candidate never knowing they were invited.
  final String? error;
}

abstract class EmailSender {
  Future<EmailSendResult> send({
    required String to,
    required String subject,
    required String body,
  });
}

/// The default when no real credential has been configured. Every send fails
/// with a reason that says exactly what to do about it, rather than the
/// invitation silently not going out.
class NullEmailSender implements EmailSender {
  const NullEmailSender();

  @override
  Future<EmailSendResult> send({
    required String to,
    required String subject,
    required String body,
  }) async {
    return const EmailSendResult.failed(
      'Email sending is not configured. Launch with '
      '--dart-define=GMAIL_ADDRESS=you@gmail.com '
      '--dart-define=GMAIL_APP_PASSWORD=your-16-character-app-password '
      '(Google Account → Security → App Passwords) to enable it.',
    );
  }
}
