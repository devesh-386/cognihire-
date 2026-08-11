/// A specific hiring campaign for a [Role] — "Backend Engineer — August 2026
/// Intake" — so two campaigns for the same role (or two different
/// organizations both hiring the same title) never share a candidate
/// pipeline. See infra/migrations/0008_intakes.sql for the enforcement:
/// organization_id can never drift from the role's real organization, and
/// every candidate created against an intake carries intake_id forward.
library;

enum IntakeStatus {
  draft('draft'),
  active('active'),
  paused('paused'),
  closed('closed');

  const IntakeStatus(this.wireValue);

  final String wireValue;

  static IntakeStatus fromWire(String value) => IntakeStatus.values.firstWhere(
        (s) => s.wireValue == value,
        orElse: () => throw FormatException('unknown intake status: $value'),
      );
}

class Intake {
  const Intake({
    required this.id,
    required this.organizationId,
    required this.roleId,
    required this.name,
    required this.status,
    required this.createdAt,
    this.googleFormId,
    this.applicationUrl,
    this.closedAt,
  });

  final String id;
  final String organizationId;
  final String roleId;
  final String name;
  final IntakeStatus status;
  final DateTime createdAt;

  /// Set once the Google Form automation (Phase B) has created and
  /// associated a form with this intake — null until then.
  final String? googleFormId;
  final String? applicationUrl;
  final DateTime? closedAt;
}
