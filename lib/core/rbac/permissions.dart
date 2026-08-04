import '../auth/user_role.dart';
import 'permission.dart';

/// The one and only mapping from [UserRole] to [Permission].
///
/// ## Everything about who-can-do-what is in this file
///
/// That is the entire point. If a reviewer wants to answer "can a candidate
/// read somebody else's report?", they read one table here rather than auditing
/// the widget tree. If the answer needs to change, it changes here and a test
/// catches every route and every widget that depended on the old answer.
///
/// ## Deny by default
///
/// [AccessPolicy.can] returns false for anything not explicitly granted. A new
/// [Permission] added to the enum is therefore denied to *both* roles until
/// someone deliberately grants it, and the exhaustiveness test below fails
/// until they do. The opposite default — allow unless denied — means a
/// forgotten entry silently opens a door, which is the failure you find out
/// about from a candidate reading another candidate's transcript.
///
/// ## The two sets are disjoint apart from one entry, and that is checked
///
/// `permissions_test.dart` asserts that the only permission both roles hold is
/// [Permission.managePersonalSettings]. That is not stylistic tidiness: the
/// product claim is two genuinely separate applications, and a shared
/// capability that crept in unnoticed is that claim quietly becoming false.
abstract final class AccessPolicy {
  static const Set<Permission> _recruiter = {
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
    Permission.managePersonalSettings,
  };

  static const Set<Permission> _candidate = {
    Permission.takeInterview,
    Permission.manageOwnResume,
    Permission.configureOwnSession,
    Permission.viewOwnHistory,
    Permission.viewOwnReports,
    Permission.manageOwnProfile,
    Permission.managePersonalSettings,
  };

  /// Every permission held by [role]. Unmodifiable — a caller that could mutate
  /// this would be editing the security policy at runtime.
  static Set<Permission> forRole(UserRole role) => switch (role) {
        UserRole.recruiter => _recruiter,
        UserRole.candidate => _candidate,
      };

  /// Whether [role] may do [permission]. Deny by default.
  static bool can(UserRole role, Permission permission) =>
      forRole(role).contains(permission);

  /// Whether [role] holds *every* permission in [required].
  ///
  /// An empty [required] means "no permission needed" and returns true — used
  /// by routes that any signed-in person may open, such as sign-out.
  static bool canAll(UserRole role, Iterable<Permission> required) =>
      required.every((p) => can(role, p));

  /// Permissions granted to nobody. Should always be empty; exposed so a test
  /// can name the offenders rather than just failing a count.
  static Set<Permission> get ungranted => Permission.values
      .toSet()
      .difference(_recruiter.union(_candidate));

  /// Permissions held by more than one role. Expected to contain exactly
  /// [Permission.managePersonalSettings].
  static Set<Permission> get shared => _recruiter.intersection(_candidate);
}
