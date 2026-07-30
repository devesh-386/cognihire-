/// The Dart-side half of the Dart↔Python feature-store contract
/// (`ML_REDESIGN.md` §0.4c). No Python mirror exists yet — see
/// `cognihire-implementation-with-skills.md`'s note on 0.4c being deferred
/// until Phase 1.1 stands up a Python service — so this cannot yet be a
/// cross-language round-trip test. What it *can* do honestly today: pin down,
/// as an exact literal fixture, what this Dart implementation computes for a
/// fully-specified set of inputs. When the Python mirror is built, its job is
/// to reproduce this exact JSON for the same inputs — this file is the
/// contract it will be checked against, not a promise that contract is
/// already being enforced across languages.
library;

import 'package:cognihire/core/features/feature_assembler.dart';
import 'package:cognihire/core/features/feature_registry.dart';
import 'package:cognihire/core/session/session_event_log.dart';
import 'package:cognihire/core/telemetry/keystroke_event.dart';
import 'package:cognihire/core/telemetry/process_telemetry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a fully-specified input set produces an exact, pinned feature '
      'vector — the golden fixture a future Python mirror must reproduce',
      () {
    final t0 = DateTime.utc(2026, 1, 1, 0, 0, 0);

    final keystrokes = KeystrokeLog();
    var ms = 0;
    for (final (gap, cls, action) in [
      (0, KeycodeClass.alpha, KeystrokeAction.insert),
      (100, KeycodeClass.alpha, KeystrokeAction.insert),
      (100, KeycodeClass.digit, KeystrokeAction.insert),
      (700, KeycodeClass.symbol, KeystrokeAction.insert),
      (50, KeycodeClass.delete, KeystrokeAction.delete),
      (50, KeycodeClass.whitespace, KeystrokeAction.insert),
    ]) {
      ms += gap;
      keystrokes.add(KeystrokeEvent(
        at: t0.add(Duration(milliseconds: ms)),
        keycodeClass: cls,
        action: action,
        cursorPosition: 0,
        selectionLength: 0,
        lengthBefore: 0,
        lengthAfter: 1,
      ));
    }

    final process = ProcessTelemetry(taskStartedAt: t0);
    process.record(30, at: t0.add(const Duration(seconds: 1)));
    process.record(230, at: t0.add(const Duration(seconds: 2)));
    process.record(210, at: t0.add(const Duration(seconds: 3)));

    final events = SessionEventLog()
      ..append(SessionEventKind.sessionStarted, at: t0, payload: {'claimCount': 1})
      ..append(SessionEventKind.claimOpened, at: t0, payload: {'claimId': 'c1'});

    final vector = const FeatureAssembler().assemble(
      keystrokes: keystrokes,
      process: process.signals(),
      events: events,
    );

    expect(vector.registryVersion, featureRegistryVersion);

    // Every value pinned by name so a future regression (or a Python
    // mismatch) points at exactly which feature moved.
    const expected = <String, double?>{
      'typing.meanInterKeyIntervalMs': 200.0,
      'typing.stdInterKeyIntervalMs': 250.99800796022265,
      'typing.maxInterKeyIntervalMs': 700.0,
      'typing.minInterKeyIntervalMs': 50.0,
      'typing.medianInterKeyIntervalMs': 100.0,
      'typing.backspaceRate': 1 / 6,
      'typing.insertRate': 5 / 6,
      'typing.navRate': 0.0,
      'typing.selectionRate': 0.0,
      'typing.alphaRate': 2 / 6,
      'typing.digitRate': 1 / 6,
      'typing.symbolRate': 1 / 6,
      'typing.whitespaceRate': 1 / 6,
      'typing.modifierRate': 0.0,
      'typing.cursorTravelTotal': 0.0,
      'typing.meanSelectionLength': 0.0,
      'typing.p90InterKeyIntervalMs': 700.0,
      'typing.interKeyIntervalCV': 1.2549900398011133,
      'typing.veryFastKeystrokeRate': 0.0,
      'typing.burstCount': 2.0,
      'typing.longestBurstLength': 3.0,
      'typing.keystrokeCount': 6.0,
      'temporal.timeToFirstKeystrokeMs': 1000.0,
      'temporal.pauseCount': 0.0,
      'temporal.pauseRatio': 0.0,
      'temporal.hasEarlyStartFlag': 1.0,
      'temporal.hasLongPauseFlag': 0.0,
      'editing.revisionRatio': 20 / 230,
      'editing.bulkInsertCount': 1.0,
      'editing.bulkDeleteCount': 0.0,
      'editing.editCount': 3.0,
      'editing.totalInsertedChars': 230.0,
      'editing.totalDeletedChars': 20.0,
      'editing.largestBulkInsertChars': 200.0,
      'editing.longestPauseMs': null,
      'editing.finalAnswerLengthChars': 210.0,
      'editing.hasBulkInsertFlag': 1.0,
      'editing.hasBulkDeleteFlag': 0.0,
      'editing.averageEditSizeChars': 250 / 3,
      'editing.netToGrossRatio': 0.84,
      'editing.netCharacterChange': 210.0,
      'editing.bulkSpanShareOfTotal': 200 / 230,
      'session.eventCount': 2.0,
      'session.distinctEventKinds': 2.0,
      'session.claimOpenedCount': 1.0,
      'session.claimAnsweredCount': 0.0,
      'session.followUpCount': 0.0,
      'session.identityCheckedCount': 0.0,
      'session.integrityObservedCount': 0.0,
      // Both fixture events are at t0: span is a real zero (not null — two
      // events exist), so the span-derived rate is null (no elapsed time)
      // while the mean gap is 0.
      'session.spanMs': 0.0,
      'session.meanInterEventMs': 0.0,
      'session.eventsPerMinute': null,
      'session.answeredToOpenedRatio': 0.0,
      'session.followUpsPerAnswer': null,
      'session.completedFlag': 0.0,
      // No verification history is passed to assemble() in this fixture —
      // every identity.* feature comes out null, part of the pinned contract
      // (absent history vs. an empty run of zero checks are different facts).
      'identity.checkCount': null,
      'identity.verifiedCount': null,
      'identity.mismatchCount': null,
      'identity.uncheckedCount': null,
      'identity.measuredCount': null,
      'identity.verifiedShareOfMeasured': null,
      'identity.uncheckedShareOfChecks': null,
      'identity.meanSimilarity': null,
      'identity.minSimilarity': null,
      'identity.maxSimilarity': null,
      'identity.stdSimilarity': null,
      'identity.similarityRange': null,
      'identity.maxConsecutiveMismatches': null,
      'identity.hadCriticalMismatchFlag': null,
      'identity.firstCheckVerifiedFlag': null,
      'identity.longestUncheckedRun': null,
      // No EvidenceGraph is passed to assemble() in this fixture — every
      // graph.* feature comes out null, which is itself part of the pinned
      // contract (absent graph vs. empty graph are different facts).
      'graph.nodeCount': null,
      'graph.edgeCount': null,
      'graph.edgesPerNode': null,
      'graph.supportsEdgeCount': null,
      'graph.contradictsEdgeCount': null,
      'graph.provisionalEdgeShare': null,
      'graph.claimNodeDegree': null,
      'graph.provenanceDistanceToIdentityCheck': null,
      'graph.orphanEvidenceCount': null,
      'graph.evidenceKindDiversity': null,
      'graph.reviewerCommentNodeCount': null,
      'graph.ruleBasisEdgeShare': null,
      'graph.modelBasisEdgeShare': null,
      'graph.humanBasisEdgeShare': null,
      'graph.density': null,
      'graph.largestComponentShare': null,
    };

    expect(vector.values.length, expected.length,
        reason: 'the fixture must cover every feature the assembler emits — '
            'update both sides together');

    for (final entry in expected.entries) {
      final actual = vector.value(entry.key);
      if (entry.value == null) {
        expect(actual, isNull, reason: entry.key);
      } else {
        expect(actual, closeTo(entry.value!, 1e-9), reason: entry.key);
      }
    }
  });
}
