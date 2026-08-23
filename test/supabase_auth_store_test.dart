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
  // `role`/`organization_id` live in appMetadata (service-role/SECURITY
  // DEFINER-only — see migration 0012_auth_org_from_app_metadata.sql and
  // supabase_auth_store.dart's own comment on principalFromUser); only
  // `display_name` still comes from userMetadata, which the account holder
  // can write themselves and which therefore must never carry anything
  // security-relevant. A fixture that put role/organization_id in
  // userMetadata would test a shape principalFromUser stopped reading
  // months ago and pass regardless of what the real function does.
  supabase.User buildUser({
    String id = 'user-1',
    String? email = 'ada@example.com',
    Map<String, dynamic>? appMetadata,
    Map<String, dynamic>? userMetadata,
  }) {
    return supabase.User(
      id: id,
      appMetadata: appMetadata ?? const {},
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
        appMetadata: const {
          'role': 'recruiter',
          // American spelling: matches the backend's demo_store.create_hr_user
          // and every route that reads it back (_require_org) — see
          // supabase_auth_store.dart's principalFromUser for why this must
          // match exactly, not the organisationId Dart field name below.
          'organization_id': 'org-1',
        },
        userMetadata: const {'display_name': 'Ada'},
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
        appMetadata: const {'role': 'candidate'},
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
      final user = buildUser(appMetadata: const {});
      expect(principalFromUser(user), isNull);
    });

    test('null appMetadata role maps to null', () {
      final user = buildUser(appMetadata: null);
      expect(principalFromUser(user), isNull);
    });

    test('unrecognised role value maps to null, not a default', () {
      final user = buildUser(appMetadata: const {'role': 'superadmin'});
      expect(principalFromUser(user), isNull);
    });

    test(
      'a role in userMetadata (not appMetadata) is ignored, not honoured',
      () {
        // The regression this guards: userMetadata is writable by the
        // signed-in account itself. If principalFromUser ever fell back to
        // reading role/organization_id from there, a candidate could grant
        // themselves recruiter access by calling
        // supabase.auth.updateUser({data: {role: 'recruiter', ...}}) — no
        // server involved.
        final user = buildUser(
          appMetadata: const {},
          userMetadata: const {
            'role': 'recruiter',
            'organization_id': 'org-1',
          },
        );
        expect(principalFromUser(user), isNull);
      },
    );

    test('null email maps to null (Principal requires a non-null email)', () {
      final user = buildUser(
        email: null,
        appMetadata: const {'role': 'recruiter'},
      );
      expect(principalFromUser(user), isNull);
    });

    test('empty email maps to null', () {
      final user = buildUser(
        email: '',
        appMetadata: const {'role': 'recruiter'},
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
