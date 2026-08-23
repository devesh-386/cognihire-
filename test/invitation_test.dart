import 'package:cognihire/core/invitations/invitation.dart';
import 'package:cognihire/core/invitations/invitation_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Invitation sample({
    String id = 'inv-1',
    String code = 'ABC123',
    InvitationStatus status = InvitationStatus.pending,
    DateTime? expiresAt,
  }) =>
      Invitation(
        id: id,
        candidateName: 'Jordan Rivera',
        candidateEmail: 'jordan@example.com',
        roleId: 'role-backend',
        code: code,
        createdAt: DateTime(2026, 8, 5, 10, 30),
        status: status,
        expiresAt: expiresAt,
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

    test('expiresAt round-trips through JSON, null or set', () {
      final withExpiry =
          sample(expiresAt: DateTime(2026, 8, 12, 10, 30));
      expect(
        Invitation.fromJson(withExpiry.toJson()).expiresAt,
        DateTime(2026, 8, 12, 10, 30),
      );
      expect(Invitation.fromJson(sample().toJson()).expiresAt, isNull);
    });

    test('revoked and scheduled statuses round-trip through JSON', () {
      expect(
        Invitation.fromJson(sample(status: InvitationStatus.revoked).toJson())
            .status,
        InvitationStatus.revoked,
      );
      expect(
        Invitation.fromJson(
                sample(status: InvitationStatus.scheduled).toJson())
            .status,
        InvitationStatus.scheduled,
      );
    });

    test('isExpired is false with no expiresAt (never expires)', () {
      expect(sample().isExpired, isFalse);
    });

    test('isExpired reflects whether expiresAt has passed', () {
      final past = sample(expiresAt: DateTime(2000, 1, 1));
      final future = sample(expiresAt: DateTime(2099, 1, 1));
      expect(past.isExpired, isTrue);
      expect(future.isExpired, isFalse);
    });
  });

  group('generateInvitationCode', () {
    test('is always 6 characters from the unambiguous alphabet', () {
      final code = generateInvitationCode();
      expect(code.length, 6);
      expect(RegExp(r'^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{6}$').hasMatch(code),
          isTrue);
    });

    test('a batch of salted codes generated in one tick are all distinct',
        () {
      // The real risk this guards: bulk CSV import calls this in a tight
      // loop, faster than the clock's actual resolution advances, so relying
      // on the timestamp alone risks two candidates in one file landing on
      // the same code.
      final codes = {
        for (var i = 0; i < 200; i++) generateInvitationCode(salt: i),
      };
      expect(codes, hasLength(200));
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

    test('an expired pending invitation cannot be redeemed', () async {
      final store = InMemoryInvitationStore();
      await store.saveInvitation(
        sample(code: 'STALE', expiresAt: DateTime(2000, 1, 1)),
      );
      expect(await store.findRedeemable('STALE'), isNull);
    });

    test('an unexpired invitation with a future expiry is redeemable',
        () async {
      final store = InMemoryInvitationStore();
      await store.saveInvitation(
        sample(code: 'FRESH', expiresAt: DateTime(2099, 1, 1)),
      );
      expect(await store.findRedeemable('FRESH'), isNotNull);
    });

    test('revokeInvitation moves a pending invitation to revoked', () async {
      final store = InMemoryInvitationStore();
      await store.saveInvitation(sample(code: 'ABC123'));
      final invitation = (await store.listInvitations()).invitations.single;

      await store.revokeInvitation(invitation);

      final after = (await store.listInvitations()).invitations.single;
      expect(after.status, InvitationStatus.revoked);
    });

    test('a revoked invitation cannot be redeemed', () async {
      final store = InMemoryInvitationStore();
      await store.saveInvitation(sample(code: 'ABC123'));
      final invitation = (await store.listInvitations()).invitations.single;
      await store.revokeInvitation(invitation);

      expect(await store.findRedeemable('ABC123'), isNull);
    });

    test('revoking an already-accepted invitation is a no-op, not an error',
        () async {
      // HR clicking Revoke on something a candidate just redeemed a moment
      // ago should not throw or silently un-accept it.
      final store = InMemoryInvitationStore();
      await store.saveInvitation(
        sample(code: 'ABC123', status: InvitationStatus.accepted),
      );
      final invitation = (await store.listInvitations()).invitations.single;

      await store.revokeInvitation(invitation);

      final after = (await store.listInvitations()).invitations.single;
      expect(after.status, InvitationStatus.accepted);
    });
  });
}
