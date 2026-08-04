import 'package:cognihire/app/routes.dart';
import 'package:cognihire/core/auth/principal.dart';
import 'package:cognihire/core/auth/user_role.dart';
import 'package:cognihire/core/rbac/permissions.dart';
import 'package:cognihire/core/rbac/route_guard.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final recruiter =
      Principal(id: 'r1', email: 'r@example.com', role: UserRole.recruiter);
  final candidate =
      Principal(id: 'c1', email: 'c@example.com', role: UserRole.candidate);

  group('the route table itself', () {
    test('no two routes share a path', () {
      final paths = AppRoutes.all.map((r) => r.path).toList();
      expect(paths.toSet(), hasLength(paths.length),
          reason: 'a duplicate path means one of the two is unreachable, and '
              'which one wins depends on list order');
    });

    test('every route is findable by its own path', () {
      for (final route in AppRoutes.all) {
        expect(AppRoutes.find(route.path), same(route));
      }
    });

    test('every shell route requires a permission unique to its own role', () {
      // The rule that keeps the two applications actually separate, and the
      // one this suite caught being broken: /candidate/settings originally
      // required only managePersonalSettings, which both roles hold by design,
      // so a recruiter could open it. A shell route that requires *only*
      // shared permissions is reachable from the other shell.
      //
      // Asserted structurally rather than per-route so that adding a screen
      // cannot reintroduce it.
      final recruiterOnly = AccessPolicy.forRole(UserRole.recruiter)
          .difference(AccessPolicy.forRole(UserRole.candidate));
      final candidateOnly = AccessPolicy.forRole(UserRole.candidate)
          .difference(AccessPolicy.forRole(UserRole.recruiter));

      for (final route in AppRoutes.hr) {
        expect(route.requires.any(recruiterOnly.contains), isTrue,
            reason: '${route.path} requires no recruiter-exclusive permission, '
                'so a candidate can reach it');
      }
      for (final route in AppRoutes.candidate) {
        expect(route.requires.any(candidateOnly.contains), isTrue,
            reason: '${route.path} requires no candidate-exclusive permission, '
                'so a recruiter can reach it');
      }
    });

    test('every non-auth route requires at least one permission', () {
      // A route with no requirements is open to every signed-in person. That
      // may be intended one day, but it must be a decision someone made, not
      // an empty list nobody noticed.
      for (final route in [...AppRoutes.hr, ...AppRoutes.candidate]) {
        expect(route.requires, isNotEmpty,
            reason: '${route.path} is open to any signed-in user');
      }
    });
  });

  group('a candidate cannot reach the HR application', () {
    test('every HR route is forbidden', () {
      // The headline claim of the whole feature, asserted over the entire HR
      // surface rather than a sampled few.
      for (final route in AppRoutes.hr) {
        final decision = RouteResolver.resolve(route.path, candidate);
        expect(decision, isA<RouteForbidden>(),
            reason: '${route.path} must be forbidden to a candidate');
      }
    });

    test('none of them appear in a candidate\'s navigation', () {
      expect(RouteResolver.permitted(AppRoutes.hr, candidate), isEmpty);
    });
  });

  group('a recruiter cannot reach the candidate application', () {
    test('every candidate route is forbidden', () {
      for (final route in AppRoutes.candidate) {
        expect(RouteResolver.resolve(route.path, recruiter),
            isA<RouteForbidden>(),
            reason: '${route.path} must be forbidden to a recruiter');
      }
    });

    test('none of them appear in a recruiter\'s navigation', () {
      expect(RouteResolver.permitted(AppRoutes.candidate, recruiter), isEmpty);
    });
  });

  group('each role reaches its own application in full', () {
    test('a recruiter may open every HR route', () {
      for (final route in AppRoutes.hr) {
        expect(RouteResolver.resolve(route.path, recruiter),
            isA<RouteAllowed>(),
            reason: '${route.path} should be open to a recruiter');
      }
      expect(RouteResolver.permitted(AppRoutes.hr, recruiter),
          hasLength(AppRoutes.hr.length));
    });

    test('a candidate may open every candidate route', () {
      for (final route in AppRoutes.candidate) {
        expect(RouteResolver.resolve(route.path, candidate),
            isA<RouteAllowed>(),
            reason: '${route.path} should be open to a candidate');
      }
      expect(RouteResolver.permitted(AppRoutes.candidate, candidate),
          hasLength(AppRoutes.candidate.length));
    });

    test('navigation order matches the brief', () {
      expect(AppRoutes.hr.map((r) => r.title), [
        'Dashboard', 'Candidates', 'Sessions', 'Roles',
        'Reports', 'Claim Audits', 'Analytics', 'Settings',
      ]);
      expect(AppRoutes.candidate.map((r) => r.title), [
        'Home', 'Resume Analysis', 'Session Setup', 'Live Interview',
        'Interview History', 'Reports', 'Profile', 'Settings',
      ]);
    });
  });

  group('signed out', () {
    test('a protected route asks for sign-in and remembers the destination',
        () {
      final decision =
          RouteResolver.resolve(AppRoutes.hrAnalytics.path, null);
      expect(decision, isA<RouteNeedsSignIn>());
      expect((decision as RouteNeedsSignIn).intended,
          AppRoutes.hrAnalytics.path);
    });

    test('auth routes are open', () {
      for (final route in AppRoutes.auth) {
        expect(RouteResolver.resolve(route.path, null), isA<RouteAllowed>());
      }
    });
  });

  group('signed in', () {
    test('an auth route redirects to the role\'s own home', () {
      final asRecruiter = RouteResolver.resolve(AppRoutes.login.path, recruiter);
      expect((asRecruiter as RouteAlreadySignedIn).home,
          AppRoutes.hrDashboard);

      final asCandidate = RouteResolver.resolve(AppRoutes.login.path, candidate);
      expect((asCandidate as RouteAlreadySignedIn).home,
          AppRoutes.candidateHome);
    });

    test('a forbidden decision names what was missing', () {
      final decision = RouteResolver.resolve(
          AppRoutes.hrAnalytics.path, candidate) as RouteForbidden;
      expect(decision.missing, isNotEmpty);
      expect(decision.route, AppRoutes.hrAnalytics);
    });
  });

  group('unknown paths', () {
    test('are not found, for signed-in and signed-out alike', () {
      // Never a silent redirect home: that hides a mistyped link until a user
      // reports that a button goes somewhere odd.
      for (final principal in [null, recruiter, candidate]) {
        expect(RouteResolver.resolve('/hr/nope', principal),
            isA<RouteNotFound>());
      }
    });

    test('a path prefix grants nothing on its own', () {
      // Access is decided by the permission list, never by the /hr/ prefix.
      // If this ever passes because something string-matched the prefix, a
      // route registered under the wrong parent becomes a privilege escalation.
      expect(RouteResolver.resolve('/hr/', candidate), isA<RouteNotFound>());
      expect(RouteResolver.resolve('/candidate/', recruiter),
          isA<RouteNotFound>());
    });
  });
}
