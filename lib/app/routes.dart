import '../core/auth/user_role.dart';
import '../core/rbac/permission.dart';

/// Every route in the application, and the permissions each one requires.
///
/// ## One table, not a guard per screen
///
/// The brief asks for route guards that stop a candidate opening HR pages and
/// vice versa. The way that goes wrong is a guard widget wrapped around each
/// screen: forty independent checks, of which one will eventually be forgotten,
/// and no single place a reviewer can read to see the whole access surface.
///
/// Here every route declares what it needs, once. [RouteResolver] answers
/// "may this principal open this path" for all of them with the same code, and
/// `route_guard_test.dart` walks the entire table asserting that no candidate
/// route is reachable by a recruiter and no recruiter route by a candidate.
/// Adding a screen means adding a row; forgetting to add the row means the
/// route does not exist rather than existing unguarded.
///
/// ## Paths are the ones from the brief
///
/// `/auth/*`, `/hr/*`, `/candidate/*`. The prefix is a readability aid for
/// humans — access is decided by [AppRoute.requires], never by string-matching
/// the prefix. A guard that trusted the prefix would be one typo away from
/// serving `/hr/analytics` to a candidate because someone registered it as
/// `/candidate/hr/analytics`.
class AppRoute {
  const AppRoute({
    required this.path,
    required this.title,
    this.requires = const [],
    this.signedOutOnly = false,
  });

  /// The route's path. Unique across [AppRoutes.all]; a duplicate is a
  /// programming error the table test catches.
  final String path;

  /// Human-readable name, used for navigation labels and the "you cannot open
  /// this" message. Kept beside the permission so the two cannot drift.
  final String title;

  /// Permissions the principal must hold — *all* of them. Empty means any
  /// signed-in principal may open it.
  final List<Permission> requires;

  /// True for routes that only make sense when signed out, such as sign-in.
  /// A signed-in user hitting one is sent to their home rather than shown a
  /// login form for the account they are already using.
  final bool signedOutOnly;
}

/// The route table.
abstract final class AppRoutes {
  // --- Auth --------------------------------------------------------------
  static const chooseRole = AppRoute(
    path: '/auth',
    title: 'Sign in',
    signedOutOnly: true,
  );
  static const login = AppRoute(
    path: '/auth/login',
    title: 'Sign in',
    signedOutOnly: true,
  );
  static const register = AppRoute(
    path: '/auth/register',
    title: 'Create an account',
    signedOutOnly: true,
  );
  static const forgotPassword = AppRoute(
    path: '/auth/forgot-password',
    title: 'Reset your password',
    signedOutOnly: true,
  );

  // --- Recruiter ---------------------------------------------------------
  static const hrDashboard = AppRoute(
    path: '/hr/dashboard',
    title: 'Dashboard',
    requires: [Permission.viewHrDashboard],
  );
  static const hrCandidates = AppRoute(
    path: '/hr/candidates',
    title: 'Candidates',
    requires: [Permission.manageCandidates],
  );
  static const hrSessions = AppRoute(
    path: '/hr/sessions',
    title: 'Sessions',
    requires: [Permission.createSession],
  );
  static const hrRoles = AppRoute(
    path: '/hr/roles',
    title: 'Roles',
    requires: [Permission.manageJobRoles],
  );
  static const hrReports = AppRoute(
    path: '/hr/reports',
    title: 'Reports',
    requires: [Permission.viewAllReports],
  );
  static const hrClaimAudits = AppRoute(
    path: '/hr/claim-audits',
    title: 'Claim Audits',
    requires: [Permission.viewClaimAudit],
  );
  static const hrAnalytics = AppRoute(
    path: '/hr/analytics',
    title: 'Analytics',
    requires: [Permission.viewAnalytics],
  );
  static const hrSettings = AppRoute(
    path: '/hr/settings',
    title: 'Settings',
    // Both permissions: the HR settings screen exposes organisation-wide
    // controls alongside personal ones. Requiring only the personal permission
    // would make the screen reachable by anyone and hide the org controls
    // behind a second check somewhere inside it — exactly the scattered
    // checking this table exists to avoid.
    requires: [Permission.managePersonalSettings, Permission.manageOrganisation],
  );

  // --- Candidate ---------------------------------------------------------
  static const candidateHome = AppRoute(
    path: '/candidate/home',
    title: 'Home',
    requires: [Permission.takeInterview],
  );
  static const candidateResume = AppRoute(
    path: '/candidate/resume',
    title: 'Resume Analysis',
    requires: [Permission.manageOwnResume],
  );
  static const candidateSetup = AppRoute(
    path: '/candidate/setup',
    title: 'Session Setup',
    requires: [Permission.configureOwnSession],
  );
  static const candidateInterview = AppRoute(
    path: '/candidate/interview',
    title: 'Live Interview',
    requires: [Permission.takeInterview],
  );
  static const candidateHistory = AppRoute(
    path: '/candidate/history',
    title: 'Interview History',
    requires: [Permission.viewOwnHistory],
  );
  static const candidateReports = AppRoute(
    path: '/candidate/reports',
    title: 'Reports',
    requires: [Permission.viewOwnReports],
  );
  static const candidateProfile = AppRoute(
    path: '/candidate/profile',
    title: 'Profile',
    requires: [Permission.manageOwnProfile],
  );
  static const candidateSettings = AppRoute(
    path: '/candidate/settings',
    title: 'Settings',
    // Two permissions, for the reason `route_guard_test.dart` caught:
    // [Permission.managePersonalSettings] is the one capability both roles
    // deliberately hold, so requiring it alone left this route open to a
    // recruiter. Every route in an application shell must require at least one
    // permission unique to that shell's role, or the shell boundary has a hole
    // in it. `manageOwnProfile` is that permission here, mirroring how
    // [hrSettings] pairs the shared one with `manageOrganisation`.
    requires: [Permission.managePersonalSettings, Permission.manageOwnProfile],
  );

  static const List<AppRoute> auth = [
    chooseRole,
    login,
    register,
    forgotPassword,
  ];

  /// The recruiter navigation, in the order the brief lists it.
  static const List<AppRoute> hr = [
    hrDashboard,
    hrCandidates,
    hrSessions,
    hrRoles,
    hrReports,
    hrClaimAudits,
    hrAnalytics,
    hrSettings,
  ];

  /// The candidate navigation, in the order the brief lists it.
  static const List<AppRoute> candidate = [
    candidateHome,
    candidateResume,
    candidateSetup,
    candidateInterview,
    candidateHistory,
    candidateReports,
    candidateProfile,
    candidateSettings,
  ];

  static const List<AppRoute> all = [...auth, ...hr, ...candidate];

  /// Where a freshly signed-in [role] lands.
  static AppRoute homeFor(UserRole role) => switch (role) {
        UserRole.recruiter => hrDashboard,
        UserRole.candidate => candidateHome,
      };

  /// Look up a route by path, or null if no such route is registered.
  ///
  /// Null means "no such route", and the caller shows a not-found screen. It
  /// deliberately does not fall back to a home route: silently redirecting an
  /// unknown path hides typos in link construction until a user reports that a
  /// button goes to the wrong place.
  static AppRoute? find(String path) {
    for (final route in all) {
      if (route.path == path) return route;
    }
    return null;
  }
}
