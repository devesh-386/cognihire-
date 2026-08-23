/// Persistence for candidate invitations.
///
/// Abstract for the same reason [RoleStore] is: the core stays free of
/// `dart:io` so it can be tested in plain Dart and run on web. The demo uses
/// [InMemoryInvitationStore] held for the process lifetime, which is enough for
/// HR to issue an invitation and a candidate to redeem it in the same run;
/// durable-to-disk persistence is a later slice.
library;

import 'invitation.dart';

/// The result of listing invitations: what was readable, and what was not —
/// mirroring [RoleIndex] so an unreadable record surfaces rather than vanishing.
class InvitationIndex {
  const InvitationIndex({required this.invitations, required this.problem});

  final List<Invitation> invitations;
  final String? problem;

  bool get isHealthy => problem == null;
}

abstract class InvitationStore {
  Future<InvitationIndex> listInvitations();

  /// Creates or replaces an invitation, keyed on [Invitation.id].
  Future<void> saveInvitation(Invitation invitation);

  /// The pending, unexpired invitation matching [code] (case-insensitively),
  /// or null when none matches. Already-accepted, revoked, and expired
  /// invitations do not match, so a code cannot be redeemed twice, after
  /// HR withdraws it, or past its own deadline.
  Future<Invitation?> findRedeemable(String code);

  /// Withdraws [invitation] before it's redeemed — a terminal transition,
  /// same as accepting. Calling this on an already-accepted/revoked/expired
  /// invitation is a no-op, not an error: HR clicking Revoke on something
  /// that just got redeemed a moment ago should not throw in their face.
  Future<void> revokeInvitation(Invitation invitation);
}

class InMemoryInvitationStore implements InvitationStore {
  final Map<String, Invitation> _invitations = {};

  @override
  Future<InvitationIndex> listInvitations() async {
    final invitations = _invitations.values.toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return InvitationIndex(invitations: invitations, problem: null);
  }

  @override
  Future<void> saveInvitation(Invitation invitation) async {
    _invitations[invitation.id] = invitation;
  }

  @override
  Future<Invitation?> findRedeemable(String code) async {
    final needle = code.trim().toLowerCase();
    if (needle.isEmpty) return null;
    for (final invitation in _invitations.values) {
      if (invitation.status == InvitationStatus.pending &&
          !invitation.isExpired &&
          invitation.code.toLowerCase() == needle) {
        return invitation;
      }
    }
    return null;
  }

  @override
  Future<void> revokeInvitation(Invitation invitation) async {
    final current = _invitations[invitation.id];
    if (current == null || current.status != InvitationStatus.pending) return;
    _invitations[invitation.id] =
        current.copyWith(status: InvitationStatus.revoked);
  }
}
