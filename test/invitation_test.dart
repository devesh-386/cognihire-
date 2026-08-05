import 'package:cognihire/core/invitations/invitation.dart';
import 'package:cognihire/core/invitations/invitation_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Invitation sample({
    String id = 'inv-1',
    String code = 'ABC123',
    InvitationStatus status = InvitationStatus.pending,
  }) =>
      Invitation(
        id: id,
        candidateName: 'Jordan Rivera',
        candidateEmail: 'jordan@example.com',
        roleId: 'role-backend',
        code: code,
        createdAt: DateTime(2026, 8, 5, 10, 30),
        status: status,
      );

  group('Invitation model', () {
    test('round-trips through JSON', () {
      final decoded = Invitation.fromJson(sample().toJson());
      expect(decoded.id, 'inv-1');
      expect(decoded.candidateName, 'Jordan Rivera');
      expect(decoded.roleId, 'role-backend');
      expect(decoded.code, 'ABC123');
      expect(decoded.status, InvitationStatus.pending);
    });

    test('decoding is strict about a missing role', () {
      final json = sample().toJson()..remove('roleId');
      expect(() => Invitation.fromJson(json), throwsFormatException);
    });

    test('decoding rejects an unknown status', () {
      final json = sample().toJson()..['status'] = 'expired';
      expect(() => Invitation.fromJson(json), throwsFormatException);
    });

    test('copyWith changes only the status', () {
      final accepted = sample().copyWith(status: InvitationStatus.accepted);
      expect(accepted.status, InvitationStatus.accepted);
      expect(accepted.code, 'ABC123');
      expect(accepted.roleId, 'role-backend');
    });
  });

  group('InMemoryInvitationStore', () {
    test('lists newest first', () async {
      final store = InMemoryInvitationStore();
      await store.saveInvitation(Invitation(
        id: 'old',
        candidateName: 'A',
        roleId: 'r',
        code: 'OLD',
        createdAt: DateTime(2026, 1, 1),
      ));
      await store.saveInvitation(Invitation(
        id: 'new',
        candidateName: 'B',
        roleId: 'r',
        code: 'NEW',
        createdAt: DateTime(2026, 8, 1),
      ));
      final index = await store.listInvitations();
      expect(index.invitations.first.id, 'new');
    });

    test('finds a pending invitation by code, case-insensitively', () async {
      final store = InMemoryInvitationStore();
      await store.saveInvitation(sample(code: 'ABC123'));
      final found = await store.findRedeemable('abc123');
      expect(found, isNotNull);
      expect(found!.id, 'inv-1');
    });

    test('an accepted invitation cannot be redeemed again', () async {
      final store = InMemoryInvitationStore();
      await store.saveInvitation(
          sample(code: 'USED', status: InvitationStatus.accepted));
      expect(await store.findRedeemable('USED'), isNull);
    });

    test('an unknown code returns null', () async {
      final store = InMemoryInvitationStore();
      await store.saveInvitation(sample(code: 'ABC123'));
      expect(await store.findRedeemable('NOPE'), isNull);
    });
  });
}
