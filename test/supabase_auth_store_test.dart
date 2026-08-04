import 'package:cognihire/core/auth/auth_store.dart';
import 'package:cognihire/core/auth/supabase_auth_store.dart';
import 'package:cognihire/core/auth/user_role.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

/// Tests principalFromUser — the pure mapping between a Supabase [User] and
/// this app's [Principal]/[UserRole] domain types.
///
/// This is the part of `SupabaseAuthStore` testable without a live Supabase
/// project: [principalFromUser] takes a [supabase.User] value directly and
/// has no I/O. The store's sign-in/register/sign-out methods are thin
/// wrappers around `GoTrueClient` network calls and are integration-tested
/// against a real (or locally self-hosted) Supabase project — out of reach
/// in this environment, same limitation as the Compose-based infra tickets
/// (CH-0.3.x): the client SDK compiles and type-checks against the verified
/// package API (confirmed by reading gotrue 2.26.0's source directly), but
/// exercising a live network call is not something this sandbox can do.
void main() {
  supabase.User buildUser({
    String id = 'user-1',
    String? email = 'ada@example.com',
    Map<String, dynamic>? userMetadata,
  }) {
    return supabase.User(
      id: id,
      appMetadata: const {},
      userMetadata: userMetadata,
      aud: 'authenticated',
      createdAt: DateTime(2026).toIso8601String(),
      email: email,
    );
  }

  group('principalFromUser', () {
    test('null user maps to null principal', () {
      expect(principalFromUser(null), isNull);
    });

    test('maps a recruiter account correctly', () {
      final user = buildUser(
        userMetadata: const {
          'role': 'recruiter',
          'display_name': 'Ada',
          'organisation_id': 'org-1',
        },
      );

      final principal = principalFromUser(user);

      expect(principal, isNotNull);
      expect(principal!.id, 'user-1');
      expect(principal.email, 'ada@example.com');
      expect(principal.role, UserRole.recruiter);
      expect(principal.displayName, 'Ada');
      expect(principal.organisationId, 'org-1');
    });

    test('maps a candidate account correctly', () {
      final user = buildUser(
        userMetadata: const {'role': 'candidate'},
      );

      final principal = principalFromUser(user);

      expect(principal, isNotNull);
      expect(principal!.role, UserRole.candidate);
      // No display_name/organisation_id set — falls back to null, not a
      // fabricated value.
      expect(principal.displayName, isNull);
      expect(principal.organisationId, isNull);
    });

    test('missing role metadata maps to null (refuse, do not guess)', () {
      final user = buildUser(userMetadata: const {});
      expect(principalFromUser(user), isNull);
    });

    test('null userMetadata maps to null', () {
      final user = buildUser(userMetadata: null);
      expect(principalFromUser(user), isNull);
    });

    test('unrecognised role value maps to null, not a default', () {
      final user = buildUser(userMetadata: const {'role': 'superadmin'});
      expect(principalFromUser(user), isNull);
    });

    test('null email maps to null (Principal requires a non-null email)', () {
      final user = buildUser(
        email: null,
        userMetadata: const {'role': 'recruiter'},
      );
      expect(principalFromUser(user), isNull);
    });

    test('empty email maps to null', () {
      final user = buildUser(
        email: '',
        userMetadata: const {'role': 'recruiter'},
      );
      expect(principalFromUser(user), isNull);
    });
  });

  group('shared password policy (auth_store.dart)', () {
    // SupabaseAuthStore.register delegates to this exact function, the same
    // one InMemoryAuthStore.describePasswordWeakness now delegates to
    // (CH-1.1.2) — this test pins the shared contract both implementations
    // rely on.
    test('rejects a password under 12 characters', () {
      expect(describePasswordWeakness('short1'), isNotNull);
    });

    test('accepts a 12+ character password', () {
      expect(
        describePasswordWeakness('a correct horse battery staple'),
        isNull,
      );
    });
  });
}
