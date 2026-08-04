/// A single thing someone is allowed to do.
///
/// ## Why the UI asks about permissions and never about roles
///
/// The naive version of this feature is `if (user.role == UserRole.recruiter)`
/// sprinkled through the widget tree. It works until the day a third role
/// appears, or a recruiter tier loses one capability, and then the answer to
/// "who can export a report?" is spread across forty files and nobody can
/// answer it by reading anything.
///
/// Here, capability is the unit. A widget asks `can(Permission.exportReports)`.
/// The mapping from role to capability lives in exactly one table
/// (`permissions.dart`), so that question has exactly one answer and a test can
/// assert the whole matrix at once.
///
/// ## Own-versus-all is a permission distinction, not a filter
///
/// [viewOwnReports] and [viewAllReports] are separate values on purpose. The
/// tempting shortcut is one `viewReports` permission plus a query filter
/// somewhere downstream — but then the difference between "a candidate reading
/// their own result" and "a candidate reading everybody's" is a `where` clause
/// that a refactor can drop silently. Making it two permissions means removing
/// the boundary requires editing the permission table, which is reviewed.
enum Permission {
  // --- Recruiter surface -------------------------------------------------
  /// See the hiring-operations dashboard.
  viewHrDashboard,

  /// List, open, and organise candidate records.
  manageCandidates,

  /// Compare candidates against one another.
  compareCandidates,

  /// Create and configure interview sessions.
  createSession,

  /// Upload a resume on someone else's behalf.
  uploadCandidateResume,

  /// Open the evidence produced by any session.
  reviewEvidence,

  /// Read the claim audit — what was substantiated, and on what basis.
  viewClaimAudit,

  /// Read reports for every candidate in the organisation.
  viewAllReports,

  /// Export a report out of the app.
  exportReports,

  /// Read organisation-level analytics.
  viewAnalytics,

  /// Create and edit job roles (the `Role` model — skills and coverage).
  manageJobRoles,

  /// Change organisation-wide settings.
  manageOrganisation,

  // --- Candidate surface -------------------------------------------------
  /// Enter the interview workspace and answer questions.
  takeInterview,

  /// Upload and view one's *own* resume analysis.
  manageOwnResume,

  /// Set up one's own session before starting.
  configureOwnSession,

  /// Read one's own interview history.
  viewOwnHistory,

  /// Read reports about oneself, and only oneself.
  viewOwnReports,

  /// Edit one's own profile.
  manageOwnProfile,

  // --- Shared ------------------------------------------------------------
  /// Change personal app preferences (theme, accessibility, device settings).
  ///
  /// Deliberately distinct from [manageOrganisation]: both roles reach a
  /// "Settings" screen, but only one of them can change anything that affects
  /// other people.
  managePersonalSettings,
}
