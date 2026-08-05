/// An invitation for a specific candidate to interview for a specific role.
///
/// ## Why this exists
///
/// The two-login split gave HR and candidates separate experiences, but nothing
/// yet binds a particular candidate to a particular role. An [Invitation] is
/// that binding: HR issues one naming the candidate and the role, and the
/// candidate redeems it with its [code] to enter an interview already scoped to
/// that role. It is the connective tissue that makes HR → candidate → report
/// read as one case rather than two people happening to share a data store.
///
/// ## Deliberately minimal
///
/// This is not an accounts-and-email system. There is no password, no delivery
/// mechanism, no expiry policy yet — those are enterprise-blueprint concerns
/// deferred until after the demo. The invitation carries exactly what the demo
/// flow needs: who, which role, a redeemable code, and whether it has been used.
library;

/// Where an invitation is in its short lifecycle.
enum InvitationStatus {
  /// Issued by HR, not yet redeemed by the candidate.
  pending,

  /// Redeemed — the candidate has entered through it. Kept (not deleted) so HR
  /// can see that an invitation was acted on and trace it to the resulting
  /// session.
  accepted;

  String get wireValue => name;

  static InvitationStatus? fromWire(String? value) {
    for (final s in InvitationStatus.values) {
      if (s.wireValue == value) return s;
    }
    return null;
  }
}

class Invitation {
  const Invitation({
    required this.id,
    required this.candidateName,
    required this.roleId,
    required this.code,
    required this.createdAt,
    this.candidateEmail = '',
    this.status = InvitationStatus.pending,
  });

  final String id;

  /// The person being invited, as HR typed it. This becomes the candidate label
  /// the resulting session is filed under, so HR sees the report against the
  /// name they invited.
  final String candidateName;

  /// Optional contact, shown to HR. Not used to send anything (no delivery yet).
  final String candidateEmail;

  /// The role this candidate is being interviewed for. References `Role.id` in
  /// the shared role store.
  final String roleId;

  /// The token the candidate types to redeem this invitation. Short and
  /// human-enterable by design — this is a demo hand-off, not a security token.
  final String code;

  final DateTime createdAt;
  final InvitationStatus status;

  Invitation copyWith({InvitationStatus? status}) => Invitation(
        id: id,
        candidateName: candidateName,
        candidateEmail: candidateEmail,
        roleId: roleId,
        code: code,
        createdAt: createdAt,
        status: status ?? this.status,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'candidateName': candidateName,
        'candidateEmail': candidateEmail,
        'roleId': roleId,
        'code': code,
        'createdAt': createdAt.toIso8601String(),
        'status': status.wireValue,
      };

  /// Strict decoder, matching the rest of the codebase: a missing or wrongly
  /// typed field raises rather than defaulting, because an invitation silently
  /// losing its role or code would send a candidate into the wrong interview.
  factory Invitation.fromJson(Map<String, Object?> json) {
    T need<T>(String key) {
      final value = json[key];
      if (value is! T) {
        throw FormatException('Invitation.$key: expected $T, got $value');
      }
      return value;
    }

    final status = InvitationStatus.fromWire(json['status'] as String?);
    if (status == null) {
      throw FormatException('Invitation.status: unknown "${json['status']}"');
    }

    return Invitation(
      id: need<String>('id'),
      candidateName: need<String>('candidateName'),
      candidateEmail: (json['candidateEmail'] as String?) ?? '',
      roleId: need<String>('roleId'),
      code: need<String>('code'),
      createdAt: DateTime.parse(need<String>('createdAt')),
      status: status,
    );
  }
}
