/// The tenant-scoping primitive every organisation-owned record carries.
///
/// CH-1.1.1 — this ticket defines the type only; nothing constructs or reads
/// one yet. It exists so later tickets (the gateway deriving `tenant_id` from
/// a token, `tenant_id` columns + RLS policies, every domain model gaining a
/// tenant field) have one shared, validated type to depend on rather than a
/// raw `String` passed around by convention.
///
/// ## Why organisation-owned, not candidate-owned
///
/// Per ED-85 (resolving OQ-08): `Candidate`, `Role`, `ClaimAudit`, and
/// `EnrolmentProfile` are records scoped to a recruiter organisation's
/// tenant — the shape already implied by the RBAC matrix in
/// `lib/core/rbac/permissions.dart`, where the recruiter role holds
/// `manageOrganisation`/`manageCandidates`/`viewAllReports` (an owner's
/// permissions over the org's records) and the candidate role holds only
/// `viewOwnReports`/`manageOwnProfile` (a subordinate's self-scoped
/// permissions, never organisation-wide visibility). A candidate is never
/// itself a [TenantId].
///
/// ## Why a wrapped value type, not a bare `String`
///
/// A tenant id threaded through queries, RLS session variables, and JWT
/// claims as a raw `String` is one accidental swap (with a session label, a
/// candidate id, anything else string-shaped) away from a cross-tenant
/// data leak — exactly the failure mode R-05 and R-51 name. Wrapping it means
/// a function that takes a `TenantId` cannot be called with the wrong kind of
/// string by accident; the type system catches what a naming convention
/// cannot.
class TenantId {
  const TenantId._(this.value);

  /// The tenant identifier. Opaque to callers — never parsed for structure,
  /// only compared and passed through.
  final String value;

  /// Validates and wraps [value]. Deliberately strict: this type is used
  /// downstream for RLS session variables and JWT claims, where a
  /// whitespace-padded or empty id is not "close enough" — it is either a
  /// caller bug or a forged/malformed token, and both should fail loudly here
  /// rather than propagate into a query.
  factory TenantId(String value) {
    if (value.isEmpty) {
      throw ArgumentError.value(value, 'value', 'must not be empty');
    }
    if (value.trim() != value) {
      throw ArgumentError.value(
        value,
        'value',
        'must not have leading/trailing whitespace',
      );
    }
    return TenantId._(value);
  }

  /// Decode from a JSON value (expected to be the raw string). Throws
  /// [ArgumentError] via the same validation as the default constructor —
  /// there is no silent-null path for a malformed tenant claim.
  factory TenantId.fromJson(Object? json) {
    if (json is! String) {
      throw ArgumentError.value(
        json,
        'json',
        'TenantId must decode from a String, got ${json.runtimeType}',
      );
    }
    return TenantId(json);
  }

  String toJson() => value;

  @override
  String toString() => value;

  @override
  bool operator ==(Object other) => other is TenantId && other.value == value;

  @override
  int get hashCode => value.hashCode;
}
