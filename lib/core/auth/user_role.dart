/// Which of the two applications a signed-in person is using.
///
/// ## Why this is not called `Role`
///
/// [Role] is already taken, and it means something else entirely: a *job* being
/// interviewed for, with a skill list and a coverage report. That name is load-
/// bearing in the product vocabulary — the HR navigation has a "Roles" section
/// that manages exactly those. Reusing `Role` for "is this person a recruiter"
/// would collide in every file that imports both, and would make the phrase
/// "the user's role" ambiguous in code review, which is the last place you want
/// ambiguity about permissions.
///
/// So: [UserRole] is who you are, `Role` is what the job is.
///
/// ## Two values, and why there is no `admin`
///
/// A third role is easy to add and hard to remove. Every value here multiplies
/// the permission table, the route table, and the number of shell layouts that
/// have to be kept working. The brief describes two experiences; this enum has
/// two values. When an organisation-admin tier is genuinely needed it should
/// arrive with its own navigation and its own tests, not as a flag that quietly
/// widens what a recruiter can do.
enum UserRole {
  /// Recruiters, hiring managers, and the organisation running the interviews.
  recruiter('Recruiter', 'Manages candidates, sessions, and hiring operations.'),

  /// The person being interviewed. Sees their own workspace and nothing else.
  candidate('Candidate', 'Takes interviews and reviews their own results.');

  const UserRole(this.label, this.description);

  /// Shown in the UI. Not derived from [name] because "recruiter" lowercased is
  /// a wire value, and a wire value drifting into a heading is how you end up
  /// shipping "recruiter" in a title bar.
  final String label;

  /// One line explaining the role on the sign-in chooser.
  final String description;

  /// The value persisted and sent over the wire. Stable and explicit: renaming
  /// an enum constant is a refactor, but it must never silently invalidate
  /// every stored account.
  String get wireValue => name;

  /// Parse a persisted [wireValue], or null if it names no known role.
  ///
  /// Null rather than a default. A stored role that this build does not
  /// recognise means the account is from a newer version or the record is
  /// corrupt, and either way guessing [candidate] would be a security decision
  /// made by a parser. The caller must refuse the session instead.
  static UserRole? fromWire(String? value) {
    for (final role in UserRole.values) {
      if (role.wireValue == value) return role;
    }
    return null;
  }
}
