import 'dart:async';

import 'package:meta/meta.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

import 'auth_store.dart';
import 'principal.dart';
import 'user_role.dart';

/// The hosted [AuthStore] that ships (CH-1.1.2, ED-86) — replaces
/// [InMemoryAuthStore] in production.
///
/// ## Why Supabase Auth
///
/// Confirmed by ED-86, resolving OQ-03/OQ-49: `in_memory_auth_store.dart`
/// already named this successor in its own doc comment. It holds up on its
/// own merits too — self-hostable (fits the T-MVP single-box shape, ED-68,
/// with no new managed dependency required to run the whole stack), and
/// Postgres-native (composes directly with the already-decided Postgres+RLS
/// tenancy model, ED-30, instead of needing a second identity store kept in
/// sync with the first).
///
/// ## Role and organisation live in Supabase's `user_metadata`
///
/// Supabase Auth has no first-class "role" concept — [UserRole] and
/// `organisationId` are set into `user_metadata` at [register] and read back
/// out at [signIn]/[current] via [principalFromUser]. This keeps [AuthStore],
/// [Principal], and [UserRole] the single source of truth for what a role
/// *means* (permissions, shell selection); Supabase is purely the credential-
/// verification backend behind them, exactly as the interface's own doc
/// comment describes the seam's purpose.
///
/// ## Why sign-in/register revoke the session on a role mismatch
///
/// Supabase establishes a valid session the instant credentials check out —
/// before this class gets a chance to compare [UserRole]. If the caller asked
/// for `asRole: recruiter` but the account is registered as a candidate, the
/// interface contract (`asRole` is checked, not discovered) requires refusing
/// the sign-in — but by then Supabase already has a live session for that
/// user. Leaving it live would mean [current] briefly (or indefinitely, if
/// the caller doesn't re-check) reports a principal nobody asked to sign in
/// as. Both [signIn] and [register] call [supabase.GoTrueClient.signOut]
/// before returning [AuthRejected] in that case.
class SupabaseAuthStore implements AuthStore {
  SupabaseAuthStore(this._client) {
    _authStateSub = _client.auth.onAuthStateChange.listen((state) {
      _changes.add(principalFromUser(state.session?.user));
    });
  }

  final supabase.SupabaseClient _client;
  final _changes = StreamController<Principal?>.broadcast();
  late final StreamSubscription<supabase.AuthState> _authStateSub;

  @override
  Principal? get current => principalFromUser(_client.auth.currentUser);

  @override
  Stream<Principal?> get changes => _changes.stream;

  @override
  Future<Principal?> restore() async {
    // supabase_flutter persists and restores the session automatically as
    // part of Supabase.initialize() during app startup, before this store is
    // constructed — there is nothing further to fetch here. This mirrors
    // InMemoryAuthStore.restore(), which likewise just reads the already-
    // current state rather than performing I/O.
    return current;
  }

  @override
  Future<AuthResult> signIn({
    required String email,
    required String password,
    required UserRole asRole,
  }) async {
    final supabase.AuthResponse response;
    try {
      response = await _client.auth.signInWithPassword(
        email: email,
        password: password,
      );
    } on supabase.AuthException {
      // Collapses every Supabase-reported sign-in failure (wrong password,
      // no such account, unconfirmed email, ...) into invalidCredentials, per
      // the same account-enumeration reasoning AuthFailure.invalidCredentials
      // documents: this store must not tell an attacker which email
      // addresses exist by varying the error shown.
      return const AuthRejected(AuthFailure.invalidCredentials);
    } catch (_) {
      return const AuthRejected(AuthFailure.unavailable);
    }

    final user = response.user;
    if (user == null) {
      return const AuthRejected(AuthFailure.invalidCredentials);
    }

    final principal = principalFromUser(user);
    if (principal == null) {
      await _client.auth.signOut();
      return const AuthRejected(AuthFailure.unrecognisedRole);
    }
    if (principal.role != asRole) {
      await _client.auth.signOut();
      return const AuthRejected(
        AuthFailure.wrongRole,
        message: 'This account is not registered for that sign-in.',
      );
    }

    return AuthSuccess(principal);
  }

  @override
  Future<AuthResult> register({
    required String email,
    required String password,
    required UserRole asRole,
    String? displayName,
  }) async {
    final complaint = describePasswordWeakness(password);
    if (complaint != null) {
      return AuthRejected(AuthFailure.weakPassword, message: complaint);
    }

    final metadata = <String, dynamic>{'role': asRole.wireValue};
    if (displayName != null) metadata['display_name'] = displayName;

    final supabase.AuthResponse response;
    try {
      response = await _client.auth.signUp(
        email: email,
        password: password,
        data: metadata,
      );
    } on supabase.AuthException catch (error) {
      if (error.code == 'email_exists') {
        return const AuthRejected(AuthFailure.emailAlreadyRegistered);
      }
      if (error.code == 'weak_password') {
        // Supabase's own server-side password rules (e.g. leaked-password
        // checks) can reject a password that passed the length-only local
        // check above — surface it the same way as a local rejection.
        return AuthRejected(AuthFailure.weakPassword, message: error.message);
      }
      return const AuthRejected(AuthFailure.unavailable);
    } catch (_) {
      return const AuthRejected(AuthFailure.unavailable);
    }

    final user = response.user;
    if (user == null) {
      return const AuthRejected(AuthFailure.unavailable);
    }

    final principal = principalFromUser(user);
    if (principal == null) {
      // Should not happen — this store just set the role metadata itself —
      // but refuse rather than return a principal this build cannot resolve
      // permissions for.
      return const AuthRejected(AuthFailure.unrecognisedRole);
    }

    return AuthSuccess(principal);
  }

  @override
  Future<AuthResult?> requestPasswordReset(String email) async {
    try {
      await _client.auth.resetPasswordForEmail(email);
    } on supabase.AuthException {
      // Same account-enumeration reasoning as sign-in: do not let a
      // Supabase-side "no such user" error distinguish this from success.
      return null;
    } catch (_) {
      return const AuthRejected(AuthFailure.unavailable);
    }
    return null;
  }

  @override
  Future<void> signOut() async {
    try {
      // scope: local is GoTrueClient's default, stated explicitly here
      // because it is the load-bearing detail behind this method's contract
      // ("must succeed locally even if the backend is unreachable") — a
      // local-scope sign-out clears the on-device session without requiring
      // a server round trip.
      await _client.auth.signOut(scope: supabase.SignOutScope.local);
    } catch (_) {
      // The interface requires this to succeed locally regardless. Supabase's
      // local-scope sign-out clears client-side session state as its first
      // step even if a best-effort server notification later throws, so
      // swallowing here does not leave a session that looks signed-in.
    }
  }

  @override
  Future<void> dispose() async {
    await _authStateSub.cancel();
    await _changes.close();
  }
}

/// Maps a Supabase [supabase.User] into a [Principal], or `null` when the
/// user has no usable email, no `role` in `user_metadata`, or a `role` value
/// this build does not recognise (see [UserRole.fromWire]'s own doc comment
/// on why that returns `null` rather than guessing).
///
/// Pure and side-effect-free by design — this is the one part of
/// [SupabaseAuthStore] testable without a live Supabase project, and is
/// exposed for exactly that.
@visibleForTesting
Principal? principalFromUser(supabase.User? user) {
  if (user == null) return null;

  final email = user.email;
  if (email == null || email.isEmpty) return null;

  // Role and organisation come from appMetadata, not userMetadata.
  //
  // userMetadata is writable by the signed-in account itself, and this app
  // reads Supabase directly under RLS — so an organisation id taken from
  // there would be an authorisation decision made from a value the user
  // controls. The database agrees: `auth_organization_id()` reads the
  // app_metadata claim (migration 0012), and so does the backend's
  // `_require_org`. All three read the same place on purpose.
  final role = UserRole.fromWire(user.appMetadata['role'] as String?);
  if (role == null) return null;

  return Principal(
    id: user.id,
    email: email,
    role: role,
    displayName: user.userMetadata?['display_name'] as String?,
    // Wire key is `organization_id` (American spelling) — that's what the
    // backend's demo_store.create_hr_user actually writes and what
    // `_require_org` and every backend route already read back. This field
    // stays `organisationId` on the Dart side; only the lookup key had to
    // match the real contract.
    organisationId: user.appMetadata['organization_id'] as String?,
  );
}
