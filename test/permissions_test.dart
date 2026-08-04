import 'package:cognihire/core/auth/auth_store.dart';
import 'package:cognihire/core/auth/in_memory_auth_store.dart';
import 'package:cognihire/core/auth/principal.dart';
import 'package:cognihire/core/auth/user_role.dart';
import 'package:cognihire/core/rbac/permission.dart';
import 'package:cognihire/core/rbac/permissions.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('the permission matrix', () {
    test('every permission is granted to someone', () {
      // A permission nobody holds is either dead code or — much worse — a
      // capability someone forgot to grant, which shows up as a screen that is
      // unreachable for every user and looks like a routing bug.
      expect(AccessPolicy.ungranted, isEmpty,
          reason: 'these permissions are held by no role at all');
    });

    test('the two roles overlap on personal settings and nothing else', () {
      // The product claim is two separate applications. Any other shared
      // capability means that claim has quietly stopped being true.
      expect(AccessPolicy.shared, {Permission.managePersonalSettings});
    });

    test('a candidate cannot reach any recruiter capability', () {
      const forbidden = [
        Permission.viewHrDashboard,
        Permission.manageCandidates,
        Permission.compareCandidates,
        Permission.createSession,
        Permission.uploadCandidateResume,
        Permission.reviewEvidence,
        Permission.viewClaimAudit,
        Permission.viewAllReports,
        Permission.exportReports,
        Permission.viewAnalytics,
        Permission.manageJobRoles,
        Permission.manageOrganisation,
      ];
      for (final p in forbidden) {
        expect(AccessPolicy.can(UserRole.candidate, p), isFalse,
            reason: 'a candidate must not hold ${p.name}');
      }
    });

    test('a recruiter holds no candidate-scoped capability', () {
      // Not symmetry for its own sake. "Own resume" and "own reports" mean
      // *the signed-in person's*, and a recruiter holding them would make
      // "own" ambiguous at exactly the point where it is doing security work.
      const forbidden = [
        Permission.takeInterview,
        Permission.manageOwnResume,
        Permission.configureOwnSession,
        Permission.viewOwnHistory,
        Permission.viewOwnReports,
        Permission.manageOwnProfile,
      ];
      for (final p in forbidden) {
        expect(AccessPolicy.can(UserRole.recruiter, p), isFalse,
            reason: 'a recruiter must not hold ${p.name}');
      }
    });

    test('viewOwnReports does not imply viewAllReports', () {
      // The distinction these two exist for. If this ever passes trivially
      // because one of them was deleted in favour of a query filter, the
      // boundary between "my result" and "everyone's results" has moved out of
      // the permission table and into a `where` clause nobody reviews.
      expect(AccessPolicy.can(UserRole.candidate, Permission.viewOwnReports),
          isTrue);
      expect(AccessPolicy.can(UserRole.candidate, Permission.viewAllReports),
          isFalse);
    });

    test('canAll requires every permission, and an empty list is allowed', () {
      expect(
        AccessPolicy.canAll(UserRole.recruiter,
            [Permission.viewAllReports, Permission.exportReports]),
        isTrue,
      );
      expect(
        AccessPolicy.canAll(UserRole.recruiter,
            [Permission.viewAllReports, Permission.takeInterview]),
        isFalse,
      );
      expect(AccessPolicy.canAll(UserRole.candidate, const []), isTrue);
    });
  });

  group('Principal', () {
    Principal principal(UserRole role) =>
        Principal(id: 'u1', email: 'a@example.com', role: role);

    test('delegates access questions to the policy', () {
      expect(principal(UserRole.recruiter).can(Permission.exportReports),
          isTrue);
      expect(principal(UserRole.candidate).can(Permission.exportReports),
          isFalse);
    });

    test('owns() is true only for its own subject id', () {
      final p = principal(UserRole.candidate);
      expect(p.owns('u1'), isTrue);
      expect(p.owns('u2'), isFalse);
    });
  });

  group('UserRole wire values', () {
    test('round-trip through the wire format', () {
      for (final role in UserRole.values) {
        expect(UserRole.fromWire(role.wireValue), role);
      }
    });

    test('an unknown or missing role parses to null, never a default', () {
      // Defaulting here would be a security decision made by a parser. A
      // corrupt or newer-version record must fail the sign-in, not quietly
      // become whichever role the author listed first.
      expect(UserRole.fromWire('admin'), isNull);
      expect(UserRole.fromWire(''), isNull);
      expect(UserRole.fromWire(null), isNull);
    });
  });

  group('InMemoryAuthStore', () {
    test('sign-in succeeds for the right role', () async {
      final store = InMemoryAuthStore.withAccount(
        email: 'ada@example.com',
        password: 'correct horse battery',
        role: UserRole.recruiter,
      );
      final result = await store.signIn(
        email: 'ada@example.com',
        password: 'correct horse battery',
        asRole: UserRole.recruiter,
      );
      expect(result, isA<AuthSuccess>());
      expect((result as AuthSuccess).principal.email, 'ada@example.com');
      expect(store.current?.role, UserRole.recruiter);
    });

    test('a wrong password and an unknown account are indistinguishable',
        () async {
      // Account enumeration. If these two ever return different failures, an
      // attacker can discover which addresses are registered by watching the
      // sign-in form.
      final store = InMemoryAuthStore.withAccount(
        email: 'ada@example.com',
        password: 'correct horse battery',
        role: UserRole.candidate,
      );
      final wrongPassword = await store.signIn(
        email: 'ada@example.com',
        password: 'nope',
        asRole: UserRole.candidate,
      ) as AuthRejected;
      final noSuchAccount = await store.signIn(
        email: 'nobody@example.com',
        password: 'nope',
        asRole: UserRole.candidate,
      ) as AuthRejected;
      expect(wrongPassword.failure, AuthFailure.invalidCredentials);
      expect(noSuchAccount.failure, AuthFailure.invalidCredentials);
      expect(wrongPassword.message, noSuchAccount.message);
    });

    test('signing in under the other role is refused', () async {
      final store = InMemoryAuthStore.withAccount(
        email: 'ada@example.com',
        password: 'correct horse battery',
        role: UserRole.candidate,
      );
      final result = await store.signIn(
        email: 'ada@example.com',
        password: 'correct horse battery',
        asRole: UserRole.recruiter,
      );
      expect((result as AuthRejected).failure, AuthFailure.wrongRole);
      expect(store.current, isNull, reason: 'no session may be established');
    });

    test('emails are matched case-insensitively and trimmed', () async {
      final store = InMemoryAuthStore.withAccount(
        email: 'Ada@Example.com',
        password: 'correct horse battery',
        role: UserRole.candidate,
      );
      final result = await store.signIn(
        email: '  ada@example.com ',
        password: 'correct horse battery',
        asRole: UserRole.candidate,
      );
      expect(result, isA<AuthSuccess>());
    });

    test('registration refuses a duplicate address and a short password',
        () async {
      final store = InMemoryAuthStore();
      final first = await store.register(
        email: 'ada@example.com',
        password: 'correct horse battery',
        asRole: UserRole.candidate,
      );
      expect(first, isA<AuthSuccess>());

      final duplicate = await store.register(
        email: 'ada@example.com',
        password: 'correct horse battery',
        asRole: UserRole.candidate,
      );
      expect((duplicate as AuthRejected).failure,
          AuthFailure.emailAlreadyRegistered);

      final weak = await store.register(
        email: 'grace@example.com',
        password: 'short',
        asRole: UserRole.candidate,
      ) as AuthRejected;
      expect(weak.failure, AuthFailure.weakPassword);
      expect(weak.message, isNotNull);
    });

    test('sign-out clears the session and notifies listeners', () async {
      final store = InMemoryAuthStore.withAccount(
        email: 'ada@example.com',
        password: 'correct horse battery',
        role: UserRole.recruiter,
      );
      final seen = <Principal?>[];
      store.changes.listen(seen.add);

      await store.signIn(
        email: 'ada@example.com',
        password: 'correct horse battery',
        asRole: UserRole.recruiter,
      );
      await store.signOut();
      await Future<void>.delayed(Duration.zero);

      expect(store.current, isNull);
      expect(seen.last, isNull);
      await store.dispose();
    });

    test('password reset never reveals whether the address exists', () async {
      final store = InMemoryAuthStore.withAccount(
        email: 'ada@example.com',
        password: 'correct horse battery',
        role: UserRole.candidate,
      );
      expect(await store.requestPasswordReset('ada@example.com'), isNull);
      expect(await store.requestPasswordReset('nobody@example.com'), isNull);
    });
  });
}
