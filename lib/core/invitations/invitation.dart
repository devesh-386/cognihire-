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
  /// Created ahead of time (the self-hosted Apply page's auto-invite path —
  /// see infra/apply-webhook), but its code hasn't been emailed yet
  /// (`code_send_at` hasn't arrived — infra/reminder-scheduler sends it and
  /// advances the row to [pending]). Not redeemable: `get_redeemable_invitation`
  /// and `accept_invitation` only ever match `status = 'pending'`.
  /// invitations_screen.dart's manual HR-invite path skips this state
  /// entirely and creates rows as [pending] directly.
  scheduled,

  /// Issued by HR, not yet redeemed by the candidate.
  pending,

  /// Redeemed — the candidate has entered through it. Kept (not deleted) so HR
  /// can see that an invitation was acted on and trace it to the resulting
  /// session.
  accepted,

  /// HR withdrew it before it was redeemed. Terminal, like [accepted] — kept
  /// rather than deleted so HR can see it was deliberately withdrawn, not
  /// just quietly vanish. A revoked code stops working immediately: the
  /// server-side RPCs only ever match `status = 'pending'`, so leaving this
  /// state is enough on its own — no separate "is revoked" check needed
  /// anywhere a redemption happens.
  revoked;

  String get wireValue => name;

  static InvitationStatus? fromWire(String? value) {
    for (final s in InvitationStatus.values) {
      if (s.wireValue == value) return s;
    }
    return null;
  }
}

// Six characters, unambiguous alphabet (no 0/O/1/I) — short enough to read
// aloud, distinct enough not to collide by typo. Shared by every place an
// Invitation gets created (single invite, bulk CSV import) so the shape of a
// code is defined once.
const _codeAlphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

/// [salt] distinguishes codes generated in the same batch (bulk CSV import
/// can create dozens in a tight loop, faster than the clock's actual
/// resolution advances) — pass the row index so two candidates in one file
/// never land on the same code even if their timestamps read identical.
String generateInvitationCode({int salt = 0}) {
  final seed = DateTime.now().microsecondsSinceEpoch + salt * 104729;
  final buffer = StringBuffer();
  var n = seed;
  for (var i = 0; i < 6; i++) {
    buffer.write(_codeAlphabet[n % _codeAlphabet.length]);
    n ~/= _codeAlphabet.length;
    if (n == 0) n = seed ~/ (i + 7);
  }
  return buffer.toString();
}

/// How long a manually-issued (invitations_screen.dart) invitation stays
/// redeemable if HR doesn't set anything else — matches interview_codes'
/// `expires_in_hours` default of 72h, same reasoning: long enough to
/// actually reach the candidate, short enough that a code isn't usable
/// indefinitely.
const defaultInvitationValidity = Duration(hours: 72);

class Invitation {
  const Invitation({
    required this.id,
    required this.candidateName,
    required this.roleId,
    required this.code,
    required this.createdAt,
    this.candidateEmail = '',
    this.status = InvitationStatus.pending,
    this.expiresAt,
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

  /// Null means "never expires" — the pre-hardening behaviour, and still
  /// what a row from before this field existed reads as. Only newly-created
  /// invitations set it (see `_InviteDialogState._save` and
  /// `buildInvitationsFromRows`).
  final DateTime? expiresAt;

  bool get isExpired =>
      expiresAt != null && expiresAt!.isBefore(DateTime.now());

  Invitation copyWith({InvitationStatus? status}) => Invitation(
        id: id,
        candidateName: candidateName,
        candidateEmail: candidateEmail,
        roleId: roleId,
        code: code,
        createdAt: createdAt,
        status: status ?? this.status,
        expiresAt: expiresAt,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'candidateName': candidateName,
        'candidateEmail': candidateEmail,
        'roleId': roleId,
        'code': code,
        'createdAt': createdAt.toIso8601String(),
        'status': status.wireValue,
        'expiresAt': expiresAt?.toIso8601String(),
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

    final expiresAtRaw = json['expiresAt'] as String?;

    return Invitation(
      id: need<String>('id'),
      candidateName: need<String>('candidateName'),
      candidateEmail: (json['candidateEmail'] as String?) ?? '',
      roleId: need<String>('roleId'),
      code: need<String>('code'),
      createdAt: DateTime.parse(need<String>('createdAt')),
      status: status,
      expiresAt: expiresAtRaw == null ? null : DateTime.parse(expiresAtRaw),
    );
  }
}
