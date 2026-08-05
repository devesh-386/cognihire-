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

  /// The pending invitation matching [code] (case-insensitively), or null when
  /// no pending invitation has that code. Already-accepted invitations do not
  /// match, so a code cannot be redeemed twice.
  Future<Invitation?> findRedeemable(String code);
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
          invitation.code.toLowerCase() == needle) {
        return invitation;
      }
    }
    return null;
  }
}
