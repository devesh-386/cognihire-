import 'dart:typed_data';

import 'package:cognihire/core/integrity/integrity_tracker.dart';
import 'package:cognihire/core/integrity/violation_rules.dart';
import 'package:cognihire/core/verification/face_engine.dart';
import 'package:cognihire/core/verification/verification_result.dart';
import 'package:cognihire/core/verification/verification_session.dart';
import 'package:flutter_test/flutter_test.dart';

/// Engine stub whose behaviour each test sets explicitly.
class _FakeEngine implements FaceEngine {
  _FakeEngine();

  FaceFrameAnalysis? next;
  Object? throwThis;
  int calls = 0;

  @override
  Future<FaceFrameAnalysis> analyseFrame(Uint8List bytes) async {
    calls++;
    if (throwThis != null) throw throwThis!;
    return next ??
        const FaceFrameAnalysis(faceDetected: false, embedding: null);
  }
}

Uint8List _frame() => Uint8List.fromList([1, 2, 3]);

List<double> _vec(double seed) => List.generate(64, (i) => seed + i * 0.001);

void main() {
  late _FakeEngine engine;
  late IntegrityTracker tracker;

  setUp(() {
    engine = _FakeEngine();
    tracker = IntegrityTracker();
  });

  VerificationSession session({
    List<double>? enrolled,
    Future<Uint8List?> Function()? grabber,
  }) =>
      VerificationSession(
        engine: engine,
        grabFrame: grabber ?? () async => _frame(),
        tracker: tracker,
        enrolledEmbedding: enrolled,
      );

  test('no enrolled profile yields Unchecked and logs nothing', () async {
    final s = session();
    final r = await s.checkNow();

    expect(r, isA<Unchecked>());
    expect((r as Unchecked).reason, UncheckedReason.noEnrolledProfile);
    expect(tracker.events, isEmpty);
    expect(engine.calls, 0, reason: 'must not call the engine with no profile');
  });

  test('no camera frame yields Unchecked, not a violation', () async {
    final s = session(enrolled: _vec(0.5), grabber: () async => null);
    final r = await s.checkNow();

    expect((r as Unchecked).reason, UncheckedReason.noCamera);
    expect(tracker.events, isEmpty,
        reason: 'system failure must not penalise the candidate');
  });

  test('engine unreachable yields Unchecked, not a mismatch', () async {
    engine.throwThis = const FaceEngineUnavailable('down');
    final s = session(enrolled: _vec(0.5));
    final r = await s.checkNow();

    expect(r, isA<Unchecked>());
    expect((r as Unchecked).reason, UncheckedReason.serviceUnreachable);
    expect(r.isVerified, isFalse);
    expect(tracker.events, isEmpty);
    expect(s.consecutiveMismatches, 0);
  });

  test('no face in frame yields Unchecked and preserves strikes', () async {
    final enrolled = _vec(0.5);
    final s = session(enrolled: enrolled);

    // One real mismatch first.
    engine.next = FaceFrameAnalysis(
      faceDetected: true,
      embedding: _vec(0.5).reversed.map((v) => -v).toList(),
    );
    await s.checkNow();
    final strikesAfterMismatch = s.consecutiveMismatches;
    expect(strikesAfterMismatch, greaterThan(0));

    // Then an unmeasurable interval.
    engine.next = const FaceFrameAnalysis(faceDetected: false, embedding: null);
    final r = await s.checkNow();

    expect((r as Unchecked).reason, UncheckedReason.noFaceInFrame);
    expect(s.consecutiveMismatches, strikesAfterMismatch,
        reason: 'an unmeasured interval neither adds nor clears strikes');
  });

  test('matching face verifies and clears strikes', () async {
    final enrolled = _vec(0.5);
    final s = session(enrolled: enrolled);

    engine.next = FaceFrameAnalysis(
      faceDetected: true,
      embedding: List<double>.from(enrolled),
    );
    final r = await s.checkNow();

    expect(r, isA<Verified>());
    expect(s.consecutiveMismatches, 0);
    expect(tracker.events, isEmpty);
  });

  test('mismatch logs an integrity event and escalates to critical', () async {
    final enrolled = List<double>.filled(4, 0)
      ..setAll(0, [1.0, 0.0, 1.0, 0.0]);
    final s = session(enrolled: enrolled);

    engine.next = const FaceFrameAnalysis(
      faceDetected: true,
      embedding: [0.0, 1.0, 0.0, 1.0], // orthogonal == different person
    );

    Mismatch? critical;
    s.onCritical.listen((m) => critical = m);

    await s.checkNow();
    expect(s.consecutiveMismatches, 1);
    await s.checkNow();
    expect(s.consecutiveMismatches, 2);
    await s.checkNow();
    expect(s.consecutiveMismatches, 3);

    // Give the broadcast stream a turn.
    await Future<void>.delayed(Duration.zero);

    expect(critical, isNotNull, reason: '3rd consecutive mismatch is critical');
    expect(critical!.isCritical, isTrue);
    expect(tracker.events.length, 3);
    expect(tracker.events.first.rule, ViolationRule.identityMismatch);
    // Three observations logged in order; no score is summed from them.
    expect(tracker.events.first.occurrenceIndex, 3);
  });

  test('a verified check between mismatches resets the strike count', () async {
    final enrolled = [1.0, 0.0, 1.0, 0.0];
    final s = session(enrolled: enrolled);

    engine.next = const FaceFrameAnalysis(
      faceDetected: true,
      embedding: [0.0, 1.0, 0.0, 1.0],
    );
    await s.checkNow();
    await s.checkNow();
    expect(s.consecutiveMismatches, 2);

    engine.next = FaceFrameAnalysis(
      faceDetected: true,
      embedding: List<double>.from(enrolled),
    );
    await s.checkNow();
    expect(s.consecutiveMismatches, 0);
  });

  test('every attempt is published, including unmeasured ones', () async {
    final s = session(enrolled: _vec(0.5));
    final seen = <VerificationResult>[];
    s.results.listen(seen.add);

    engine.next = const FaceFrameAnalysis(faceDetected: false, embedding: null);
    await s.checkNow();
    engine.next = FaceFrameAnalysis(
      faceDetected: true,
      embedding: _vec(0.5),
    );
    await s.checkNow();

    await Future<void>.delayed(Duration.zero);

    expect(seen.length, 2);
    expect(seen[0], isA<Unchecked>());
    expect(seen[1], isA<Verified>());
  });

  test('jittered interval stays within bounds and never goes sub-second', () {
    final s = VerificationSession(
      engine: engine,
      grabFrame: () async => _frame(),
      tracker: tracker,
      baseInterval: const Duration(seconds: 20),
      jitter: const Duration(seconds: 5),
    );
    // Exercise the private scheduler indirectly via many draws.
    for (var i = 0; i < 200; i++) {
      final delay = s.nextDelay();
      expect(delay.inMilliseconds, greaterThanOrEqualTo(1000));
      expect(delay.inSeconds, lessThanOrEqualTo(25));
      expect(delay.inSeconds, greaterThanOrEqualTo(15));
    }
  });
}
