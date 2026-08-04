import 'dart:async';

import 'auth_store.dart';
// Imported a second time, prefixed, purely to reach the top-level
// describePasswordWeakness function below without ambiguity against this
// class's own static method of the same name.
import 'auth_store.dart' as shared;
import 'principal.dart';
import 'user_role.dart';

/// An [AuthStore] that keeps accounts in a map for the length of the process.
///
/// ## This is a test double and a development convenience, not a login system
///
/// Passwords are held in memory as plain strings and compared with `==`. That
/// is fine for what this exists to do — let the router, the guards, the shells,
/// and every widget that asks about a permission be built and tested with no
/// network and no backend project — and it is unacceptable for anything a real
/// person's password goes into. The hosted [SupabaseAuthStore] is the one that
/// ships.
///
/// To make that impossible to get wrong by accident, [assertNotProduction] is
/// called from the constructor and throws in release builds. A misconfigured
/// build that fell back to this store would otherwise accept any account it had
/// been seeded with, silently, and look completely normal.
class InMemoryAuthStore implements AuthStore {
  InMemoryAuthStore() {
    assertNotProduction();
  }

  /// Convenience for tests and demos: an account that can immediately sign in.
  factory InMemoryAuthStore.withAccount({
    required String email,
    required String password,
    required UserRole role,
    String? displayName,
    String? organisationId,
  }) {
    final store = InMemoryAuthStore();
    store.addAccount(
      email: email,
      password: password,
      role: role,
      displayName: displayName,
      organisationId: organisationId,
    );
    return store;
  }

  final Map<String, _Account> _accounts = {};
  final StreamController<Principal?> _changes =
      StreamController<Principal?>.broadcast();

  Principal? _current;
  var _nextId = 1;

  /// Throws if this store is instantiated in a release build.
  ///
  /// Separate and named so the reason survives: this is not defensive
  /// paranoia, it is the difference between "the backend is misconfigured and
  /// the app fails loudly" and "the backend is misconfigured and the app
  /// authenticates people against a map".
  static void assertNotProduction() {
    const isRelease = bool.fromEnvironment('dart.vm.product');
    if (isRelease) {
      throw StateError(
        'InMemoryAuthStore was constructed in a release build. It compares '
        'passwords in plaintext and must never authenticate a real user. '
        'This means the real AuthStore failed to configure — fix that rather '
        'than relaxing this check.',
      );
    }
  }

  /// Register an account directly, bypassing password policy. Tests only.
  Principal addAccount({
    required String email,
    required String password,
    required UserRole role,
    String? displayName,
    String? organisationId,
  }) {
    final key = _key(email);
    final principal = Principal(
      id: 'user-${_nextId++}',
      email: email.trim(),
      role: role,
      displayName: displayName,
      organisationId: organisationId,
    );
    _accounts[key] = _Account(password: password, principal: principal);
    return principal;
  }

  @override
  Principal? get current => _current;

  @override
  Stream<Principal?> get changes => _changes.stream;

  @override
  Future<Principal?> restore() async => _current;

  @override
  Future<AuthResult> signIn({
    required String email,
    required String password,
    required UserRole asRole,
  }) async {
    final account = _accounts[_key(email)];

    // Both "no account" and "wrong password" collapse to one failure, for the
    // account-enumeration reason documented on AuthFailure.invalidCredentials.
    if (account == null || account.password != password) {
      return const AuthRejected(AuthFailure.invalidCredentials);
    }
    if (account.principal.role != asRole) {
      return const AuthRejected(
        AuthFailure.wrongRole,
        message: 'This account is not registered for that sign-in.',
      );
    }
    _emit(account.principal);
    return AuthSuccess(account.principal);
  }

  @override
  Future<AuthResult> register({
    required String email,
    required String password,
    required UserRole asRole,
    String? displayName,
  }) async {
    if (_accounts.containsKey(_key(email))) {
      return const AuthRejected(AuthFailure.emailAlreadyRegistered);
    }
    final complaint = describePasswordWeakness(password);
    if (complaint != null) {
      return AuthRejected(AuthFailure.weakPassword, message: complaint);
    }
    final principal = addAccount(
      email: email,
      password: password,
      role: asRole,
      displayName: displayName,
    );
    _emit(principal);
    return AuthSuccess(principal);
  }

  @override
  Future<AuthResult?> requestPasswordReset(String email) async => null;

  @override
  Future<void> signOut() async => _emit(null);

  @override
  Future<void> dispose() async {
    await _changes.close();
  }

  void _emit(Principal? principal) {
    _current = principal;
    if (!_changes.isClosed) _changes.add(principal);
  }

  /// Emails are matched case-insensitively and trimmed. Without this,
  /// " Ada@example.com" and "ada@example.com" are two accounts, and the second
  /// person to register finds the address mysteriously free.
  static String _key(String email) => email.trim().toLowerCase();

  /// The password policy. Delegates to the shared top-level
  /// [describePasswordWeakness] in `auth_store.dart` (CH-1.1.2) so this store
  /// and `SupabaseAuthStore` cannot drift apart — kept as a static method
  /// here too since existing call sites use
  /// `InMemoryAuthStore.describePasswordWeakness(...)`.
  static String? describePasswordWeakness(String password) =>
      shared.describePasswordWeakness(password);
}

class _Account {
  const _Account({required this.password, required this.principal});
  final String password;
  final Principal principal;
}
