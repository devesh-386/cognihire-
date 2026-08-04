import 'principal.dart';
import 'user_role.dart';

/// Why a sign-in or registration attempt did not succeed.
///
/// ## Why the enum is coarse on purpose
///
/// There is no `noSuchAccount` distinct from `wrongPassword`. Telling an
/// unauthenticated caller which of the two happened turns the sign-in form into
/// an account-enumeration oracle: an attacker learns which email addresses are
/// registered by watching which error comes back. Both collapse to
/// [invalidCredentials], and the UI must not embellish that with a guess.
enum AuthFailure {
  /// Wrong email, wrong password, or no such account. Deliberately one value.
  invalidCredentials,

  /// The credentials were right, but the account is registered under the other
  /// role. Distinct from [invalidCredentials] because it is not a secret — the
  /// person has already proven who they are — and because silently signing a
  /// candidate into the recruiter shell would be far worse than a clear error.
  wrongRole,

  /// Registration refused because the email is already in use.
  emailAlreadyRegistered,

  /// The password did not meet the policy. See [AuthResult.message].
  weakPassword,

  /// The backend could not be reached. Distinct from every other value because
  /// it is the only one the user can fix by checking their connection, and the
  /// only one where retrying the same input is sensible.
  unavailable,

  /// The account exists and the credentials are right, but the stored role is
  /// not one this build recognises. See [UserRole.fromWire] — the parser
  /// refuses rather than defaulting, and this is how that refusal surfaces.
  unrecognisedRole,
}

/// The outcome of an authentication attempt: a [Principal] or an [AuthFailure],
/// never both and never neither.
///
/// Modelled as a sealed pair rather than a nullable principal plus a nullable
/// error, so a caller cannot forget to check one of them. `switch` on this is
/// exhaustive and the analyzer enforces it.
sealed class AuthResult {
  const AuthResult();
}

/// Sign-in or registration succeeded.
final class AuthSuccess extends AuthResult {
  const AuthSuccess(this.principal);
  final Principal principal;
}

/// Sign-in or registration failed.
final class AuthRejected extends AuthResult {
  const AuthRejected(this.failure, {this.message});

  final AuthFailure failure;

  /// Optional detail safe to show the user. Never contains anything that would
  /// distinguish "no such account" from "wrong password".
  final String? message;
}

/// Everything the app needs from an authentication backend.
///
/// ## Why this is an interface with the backend behind it
///
/// The app is being given a hosted backend, but the authentication *decisions*
/// — which shell to mount, which routes to permit — belong to the app and are
/// tested here. Putting a seam at this boundary means the entire routing,
/// guarding, and shell-selection layer can be built and tested against
/// [InMemoryAuthStore] with no network, no project, and no credentials, exactly
/// as `AuditStore` already does for persistence.
///
/// It also means a backend outage degrades at one known point rather than
/// throwing from inside a widget build.
///
/// ## Implementations must not throw
///
/// Every failure is an [AuthRejected]. A store that throws on a dropped
/// connection forces every call site into a try/catch and will eventually crash
/// a sign-in screen, which is the worst possible place to crash — the user has
/// no way past it.
abstract interface class AuthStore {
  /// The currently signed-in principal, or null. Read synchronously because the
  /// router consults it on every navigation and cannot await.
  Principal? get current;

  /// Emits on every change to [current], including sign-out (which emits null).
  /// The router listens so that a session expiring mid-use redirects rather
  /// than leaving a candidate staring at a dead screen.
  Stream<Principal?> get changes;

  /// Restore a previously persisted session, if any. Called once at startup.
  /// Returns the restored principal or null; never throws.
  Future<Principal?> restore();

  /// Authenticate [email]/[password] and require the account to be [asRole].
  ///
  /// [asRole] is checked rather than discovered because the sign-in screen asks
  /// the user to pick first. Signing a person into whichever shell their
  /// account happens to hold would make the chooser decorative, and would make
  /// a mistyped email land someone in an interface they did not ask for.
  Future<AuthResult> signIn({
    required String email,
    required String password,
    required UserRole asRole,
  });

  /// Create an account for [asRole].
  Future<AuthResult> register({
    required String email,
    required String password,
    required UserRole asRole,
    String? displayName,
  });

  /// Begin a password reset for [email].
  ///
  /// Returns normally whether or not the address is registered — the same
  /// account-enumeration argument as [AuthFailure.invalidCredentials]. The UI
  /// says "if that address has an account, a link is on its way", which is true
  /// either way. Only [AuthFailure.unavailable] is ever reported.
  Future<AuthResult?> requestPasswordReset(String email);

  /// Discard the session. Must succeed locally even if the backend is
  /// unreachable: a user who cannot sign out on a shared machine is a real
  /// problem, and a server that will not confirm it is not a reason to keep
  /// them signed in.
  Future<void> signOut();

  /// Release resources. Called when the app shuts down.
  Future<void> dispose();
}
