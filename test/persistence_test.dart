import 'dart:convert';
import 'dart:io';

import 'package:cognihire/core/claims/claim.dart';
import 'package:cognihire/core/claims/claim_audit.dart';
import 'package:cognihire/core/persistence/audit_store.dart';
import 'package:cognihire/core/persistence/audit_store_io.dart';
import 'package:cognihire/core/persistence/json_codec.dart';
import 'package:cognihire/core/verification/verification_result.dart';
import 'package:flutter_test/flutter_test.dart';

/// An audit exercising every reported state, including the ones that admit a
/// gap. Round-tripping this is the real test: the states that say "we could not
/// measure" are exactly the ones a careless codec turns into passes.
ClaimAudit _audit({List<VerificationResult>? attempts}) {
  final start = DateTime.utc(2026, 7, 27, 9);

  return const ClaimAuditBuilder().build(
    claims: const [
      Claim(
        id: 'c1',
        text: 'Built a React dashboard',
        source: 'Resume, page 1',
        skill: 'React',
      ),
      Claim(
        id: 'c2',
        text: 'Optimised Postgres queries',
        source: 'Resume, page 1',
        skill: 'PostgreSQL',
      ),
      // No skill tag — must stay null across the round trip, never "".
      Claim(id: 'c3', text: 'Led a CI migration', source: 'Cover letter'),
    ],
    evidenceByClaimId: {
      'c1': [
        ClaimEvidence(
          observation: 'Described state lifting when asked.',
          kind: EvidenceKind.probeResponse,
          at: start.add(const Duration(minutes: 6)),
        ),
        ClaimEvidence(
          observation: '340 characters added in one step.',
          kind: EvidenceKind.processSignal,
          at: start.add(const Duration(minutes: 10)),
        ),
      ],
      'c2': [
        ClaimEvidence(
          observation: 'Could not describe the measurement method.',
          kind: EvidenceKind.probeResponse,
          at: start.add(const Duration(minutes: 21)),
        ),
      ],
    },
    reviewerAssessments: const {'c1': ClaimStatus.substantiated},
    identityAttempts: attempts ??
        [
          Verified(similarity: 96.4, at: start.add(const Duration(minutes: 1))),
          Mismatch(
            similarity: 41.2,
            strike: 1,
            strikesAllowed: 3,
            at: start.add(const Duration(minutes: 8)),
          ),
          Unchecked(
            reason: UncheckedReason.noFaceInFrame,
            at: start.add(const Duration(minutes: 15)),
          ),
        ],
    sessionStart: start,
    sessionEnd: start.add(const Duration(minutes: 38)),
  );
}

void main() {
  group('audit round trip', () {
    test('preserves findings, statuses and evidence', () {
      final restored = auditFromJson(auditToJson(_audit()));
      final original = _audit();

      expect(restored.findings.length, original.findings.length);

      for (var i = 0; i < original.findings.length; i++) {
        final before = original.findings[i];
        final after = restored.findings[i];

        expect(after.claim.id, before.claim.id);
        expect(after.claim.text, before.claim.text);
        expect(after.claim.source, before.claim.source);
        expect(after.status, before.status);
        expect(after.evidence.length, before.evidence.length);

        for (var j = 0; j < before.evidence.length; j++) {
          expect(after.evidence[j].observation, before.evidence[j].observation);
          expect(after.evidence[j].kind, before.evidence[j].kind);
          expect(after.evidence[j].at, before.evidence[j].at);
        }
      }
    });

    test('an absent skill stays null and does not become an empty string', () {
      final restored = auditFromJson(auditToJson(_audit()));
      final untagged =
          restored.findings.firstWhere((f) => f.claim.id == 'c3');

      expect(untagged.claim.skill, isNull);
    });

    test('preserves session boundaries exactly', () {
      final original = _audit();
      final restored = auditFromJson(auditToJson(original));

      expect(restored.sessionStart, original.sessionStart);
      expect(restored.sessionEnd, original.sessionEnd);
    });

    test('preserves each identity attempt as its own variant', () {
      final restored = auditFromJson(auditToJson(_audit()));

      expect(restored.identityAttempts[0], isA<Verified>());
      expect(restored.identityAttempts[1], isA<Mismatch>());
      expect(restored.identityAttempts[2], isA<Unchecked>());

      final mismatch = restored.identityAttempts[1] as Mismatch;
      expect(mismatch.strike, 1);
      expect(mismatch.strikesAllowed, 3);
      expect(mismatch.isCritical, isFalse);

      final unchecked = restored.identityAttempts[2] as Unchecked;
      expect(unchecked.reason, UncheckedReason.noFaceInFrame);
      expect(unchecked.isVerified, isFalse);
      expect(unchecked.didMeasure, isFalse);
    });

    test('derived provenance quality survives reload unchanged', () {
      final original = _audit();
      final restored = auditFromJson(auditToJson(original));

      expect(restored.provenanceQuality, original.provenanceQuality);
      expect(restored.identityChecksPerformed, original.identityChecksPerformed);
      expect(restored.identityChecksVerified, original.identityChecksVerified);
      expect(restored.summary, original.summary);
    });

    test('zero attempts reload as null coverage, never as full coverage', () {
      final restored =
          auditFromJson(auditToJson(_audit(attempts: const [])));

      expect(restored.identityCoverage, isNull);
      expect(restored.provenanceQuality, ProvenanceQuality.none);
    });
  });

  group('Unchecked carries no fabricated number', () {
    test('serialises without a similarity field at all', () {
      final json = verificationResultToJson(
        Unchecked(reason: UncheckedReason.noCamera, at: DateTime.utc(2026)),
      );

      expect(json.containsKey('similarity'), isFalse);
      expect(json['type'], 'unchecked');
    });

    test('an unchecked attempt never reloads as verified', () {
      final restored = verificationResultFromJson(
        verificationResultToJson(
          Unchecked(
            reason: UncheckedReason.serviceUnreachable,
            at: DateTime.utc(2026),
          ),
        ),
      );

      expect(restored.isVerified, isFalse);
      expect(restored.didMeasure, isFalse);
    });
  });

  group('decoding is strict', () {
    test('an unknown attempt type throws instead of defaulting', () {
      expect(
        () => verificationResultFromJson({
          'type': 'probably_fine',
          'at': DateTime.utc(2026).toIso8601String(),
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('an unknown claim status throws instead of picking the first', () {
      final json = auditToJson(_audit());
      final firstFinding =
          (json['findings']! as List).first as Map<String, Object?>;
      firstFinding['status'] = 'looksGoodToMe';

      expect(() => auditFromJson(json), throwsA(isA<FormatException>()));
    });

    test('a missing required field throws', () {
      final json = auditToJson(_audit());
      json.remove('sessionEnd');

      expect(() => auditFromJson(json), throwsA(isA<FormatException>()));
    });

    test('a verified attempt missing its similarity throws', () {
      expect(
        () => verificationResultFromJson({
          'type': 'verified',
          'at': DateTime.utc(2026).toIso8601String(),
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('a future schema version is refused rather than guessed at', () {
      final json = auditToJson(_audit());
      json['schemaVersion'] = auditSchemaVersion + 1;

      expect(() => auditFromJson(json), throwsA(isA<FormatException>()));
    });

    test('a malformed timestamp throws', () {
      final json = auditToJson(_audit());
      json['sessionStart'] = 'last tuesday';

      expect(() => auditFromJson(json), throwsA(isA<FormatException>()));
    });
  });

  group('enrolment profile', () {
    test('round-trips the embedding exactly', () {
      final profile = EnrolmentProfile(
        embedding: const [0.11, -0.42, 0.98],
        capturedAt: DateTime.utc(2026, 7, 27, 10, 30),
        faceSize: 22400,
      );

      final restored =
          enrolmentProfileFromJson(enrolmentProfileToJson(profile));

      expect(restored.embedding, profile.embedding);
      expect(restored.capturedAt, profile.capturedAt);
      expect(restored.faceSize, profile.faceSize);
    });

    test('an empty stored embedding is refused, not loaded as a reference', () {
      expect(
        () => enrolmentProfileFromJson({
          'schemaVersion': auditSchemaVersion,
          'embedding': const <double>[],
          'capturedAt': DateTime.utc(2026).toIso8601String(),
          'faceSize': 20000,
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('a non-numeric embedding entry throws', () {
      expect(
        () => enrolmentProfileFromJson({
          'schemaVersion': auditSchemaVersion,
          'embedding': const ['nope'],
          'capturedAt': DateTime.utc(2026).toIso8601String(),
          'faceSize': 20000,
        }),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('InMemoryAuditStore', () {
    test('saves, lists and loads a session', () async {
      final store = InMemoryAuditStore();
      final id = await store.saveAudit(_audit(), label: 'Alice');

      final index = await store.listSessions();
      expect(index.sessions, hasLength(1));
      expect(index.sessions.single.label, 'Alice');
      expect(index.sessions.single.claimCount, 3);
      expect(index.hasUnreadable, isFalse);

      final loaded = await store.loadAudit(id);
      expect(loaded.findings, hasLength(3));
    });

    test('loading an unknown id throws rather than returning an empty audit',
        () async {
      final store = InMemoryAuditStore();
      expect(
        () => store.loadAudit('nope'),
        throwsA(isA<StateError>()),
      );
    });

    test('enrolment survives until explicitly cleared', () async {
      final store = InMemoryAuditStore();
      expect(await store.loadEnrolment(), isNull);

      await store.saveEnrolment(EnrolmentProfile(
        embedding: const [0.5, 0.5],
        capturedAt: DateTime.utc(2026),
        faceSize: 20000,
      ));
      expect((await store.loadEnrolment())!.embedding, [0.5, 0.5]);

      await store.clearEnrolment();
      expect(await store.loadEnrolment(), isNull);
    });
  });

  group('JsonFileAuditStore', () {
    late Directory dir;
    late JsonFileAuditStore store;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('cognihire_store_test');
      store = JsonFileAuditStore(dir.path);
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('an audit survives being written and read back', () async {
      final id = await store.saveAudit(_audit(), label: 'Alice');
      final loaded = await store.loadAudit(id);

      expect(loaded.findings, hasLength(3));
      expect(loaded.identityAttempts, hasLength(3));
      expect(loaded.provenanceQuality, _audit().provenanceQuality);
      expect(loaded.summary, _audit().summary);
    });

    test('listing an empty directory yields nothing rather than throwing',
        () async {
      final index = await store.listSessions();
      expect(index.sessions, isEmpty);
      expect(index.unreadable, isEmpty);
    });

    test('sessions list newest first', () async {
      final start = DateTime.utc(2026, 7, 20);
      final older = const ClaimAuditBuilder().build(
        claims: const [Claim(id: 'x', text: 'older', source: 'Resume')],
        evidenceByClaimId: const {},
        reviewerAssessments: const {},
        identityAttempts: const [],
        sessionStart: start,
        sessionEnd: start.add(const Duration(minutes: 10)),
      );

      await store.saveAudit(older, label: 'Older');
      await store.saveAudit(_audit(), label: 'Newer');

      final index = await store.listSessions();
      expect(index.sessions.map((s) => s.label), ['Newer', 'Older']);
    });

    test('a corrupt session is reported, not silently dropped', () async {
      await store.saveAudit(_audit(), label: 'Good');
      await File('${dir.path}${Platform.pathSeparator}session-999.json')
          .writeAsString('{ this is not json');

      final index = await store.listSessions();

      expect(index.sessions, hasLength(1));
      expect(index.unreadable, hasLength(1));
      expect(index.unreadable.single.id, 'session-999');
      expect(index.total, 2);
    });

    test('a session with an unknown attempt type is reported as unreadable',
        () async {
      final payload = {
        'id': 'session-777',
        'label': 'Tampered',
        'savedAt': DateTime.utc(2026).toIso8601String(),
        'audit': auditToJson(_audit()),
      };
      final attempts =
          (payload['audit'] as Map<String, Object?>)['identityAttempts']!
              as List;
      (attempts.first as Map<String, Object?>)['type'] = 'definitely_verified';

      await File('${dir.path}${Platform.pathSeparator}session-777.json')
          .writeAsString(jsonEncode(payload));

      final index = await store.listSessions();

      expect(index.sessions, isEmpty);
      expect(index.unreadable, hasLength(1));
    });

    test('deleting removes it from the listing', () async {
      final id = await store.saveAudit(_audit(), label: 'Alice');
      expect((await store.listSessions()).sessions, hasLength(1));

      await store.deleteAudit(id);
      expect((await store.listSessions()).sessions, isEmpty);
    });

    test('no temporary file is left behind after a save', () async {
      await store.saveAudit(_audit(), label: 'Alice');

      final leftovers = await dir
          .list()
          .where((e) => e.path.endsWith('.tmp'))
          .toList();

      expect(leftovers, isEmpty);
    });

    test('enrolment persists across a fresh store on the same directory',
        () async {
      await store.saveEnrolment(EnrolmentProfile(
        embedding: const [0.1, 0.2, 0.3],
        capturedAt: DateTime.utc(2026, 7, 27),
        faceSize: 21000,
      ));

      final reopened = JsonFileAuditStore(dir.path);
      final profile = await reopened.loadEnrolment();

      expect(profile, isNotNull);
      expect(profile!.embedding, [0.1, 0.2, 0.3]);
      expect(profile.faceSize, 21000);
    });

    test('no enrolment file means not enrolled, which is a real answer',
        () async {
      expect(await store.loadEnrolment(), isNull);
    });

    test('a corrupt enrolment throws rather than reading as not enrolled',
        () async {
      await File('${dir.path}${Platform.pathSeparator}enrolment.json')
          .writeAsString('{"schemaVersion": 1}');

      expect(store.loadEnrolment(), throwsA(isA<FormatException>()));
    });
  });
}
