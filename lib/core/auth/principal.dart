import '../rbac/permission.dart';
import '../rbac/permissions.dart';
import 'user_role.dart';

/// The signed-in person: who they are, and — through [can] — what they may do.
///
/// ## Immutable, and constructed only from a verified sign-in
///
/// There is no setter for [role]. A principal whose role could be changed after
/// construction is a principal whose permissions can be escalated by any code
/// holding a reference to it, which defeats the point of having a permission
/// table at all. Changing role means signing out and signing in again.
///
/// ## [can] is the only way the UI should ask about access
///
/// Widgets call `principal.can(Permission.exportReports)`. They do not read
/// [role] and compare it. The one legitimate use of [role] outside this class
/// is choosing which application shell to mount, which is a routing decision
/// made once, not an access decision made repeatedly.
class Principal {
  const Principal({
    required this.id,
    required this.email,
    required this.role,
    this.displayName,
    this.organisationId,
  });

  /// Stable identifier from the auth backend. Used to scope "own" data — a
  /// candidate's reports are the ones whose subject is this id.
  final String id;

  final String email;

  final UserRole role;

  /// What to show in the UI. Null when the account has not set one; callers
  /// fall back to [email] rather than inventing a name.
  final String? displayName;

  /// Which organisation a recruiter belongs to. Null for candidates, who do not
  /// belong to one — a candidate interviews *with* an organisation, they are
  /// not a member of it, and modelling them as one would leak organisation
  /// data into their scope the first time somebody wrote a convenience query.
  final String? organisationId;

  /// Whether this person may do [permission]. Deny by default.
  bool can(Permission permission) => AccessPolicy.can(role, permission);

  /// Whether this person holds every permission in [required].
  bool canAll(Iterable<Permission> required) =>
      AccessPolicy.canAll(role, required);

  /// True when [subjectId] is this principal. Used wherever an "own data"
  /// permission needs to be turned into an actual row filter, so the comparison
  /// happens in one place rather than as an inline `==` at each call site.
  bool owns(String subjectId) => subjectId == id;

  @override
  String toString() => 'Principal($email, ${role.wireValue})';
}
