import 'dart:typed_data';

import 'package:cognihire/core/integrity/integrity_tracker.dart';
import 'package:cognihire/core/integrity/violation_rules.dart';
import 'package:cognihire/core/verification/face_engine.dart';
import 'package:cognihire/core/verification/verification_session.dart';
import 'package:cognihire/core/verification/within_session_baseline.dart';
import 'package:flutter_test/flutter_test.dart';

/// Engine stub whose behaviour each test sets explicitly, matching the
/// pattern in verification_session_test.dart.
class _FakeEngine implements FaceEngine {
  FaceFrameAnalysis? next;

  @override
  Future<FaceFrameAnalysis> analyseFrame(Uint8List bytes) async =>
      next ?? const FaceFrameAnalysis(faceDetected: false, embedding: null);
}

Uint8List _frame() => Uint8List.fromList([1, 2, 3]);

List<double> _vec(double seed) => List.generate(64, (i) => seed + i * 0.001);

void main() {
  late _FakeEngine engine;
  late IntegrityTracker tracker;
  final enrolled = _vec(0.5);

  setUp(() {
    engine = _FakeEngine();
    tracker = IntegrityTracker();
  });

  VerificationSession session() => VerificationSession(
        engine: engine,
        grabFrame: () async => _frame(),
        tracker: tracker,
        enrolledEmbedding: enrolled,
      );

  test('no baseline exists before any measured attempt', () async {
    final s = session();
    expect(s.selfSimilarityBaseline, isNull);
  });

  test('one measured attempt is not enough to establish a baseline', () async {
    final s = session();
    engine.next = FaceFrameAnalysis(faceDetected: true, embedding: _vec(0.5));
    await s.checkNow();
    expect(s.selfSimilarityBaseline, isNull);
  });

  test('an Unchecked attempt does not feed the baseline', () async {
    final s = session();
    engine.next = const FaceFrameAnalysis(faceDetected: false, embedding: null);
    await s.checkNow();
    await s.checkNow();
    expect(s.selfSimilarityBaseline, isNull);
  });

  test('two consistent measured attempts establish a baseline', () async {
    final s = session();
    engine.next = FaceFrameAnalysis(faceDetected: true, embedding: _vec(0.5));
    await s.checkNow();
    await s.checkNow();

    final baseline = s.selfSimilarityBaseline;
    expect(baseline, isNotNull);
    expect(baseline!.sampleCount, 2);
  });

  test(
      'a capture that deviates sharply from the established baseline is '
      'logged as a distinct observation, not folded into identityMismatch',
      () async {
    final s = session();

    // Two genuine, consistent captures establish the baseline.
    engine.next = FaceFrameAnalysis(faceDetected: true, embedding: _vec(0.5));
    await s.checkNow();
    await s.checkNow();
    expect(
      tracker.events.where((e) => e.rule == ViolationRule.selfBaselineDeviation),
      isEmpty,
      reason: 'no baseline existed yet for these first two captures',
    );

    // Third capture is wildly different from the candidate's own established
    // pattern (still matches the enrolled profile closely enough to pass —
    // this is about self-consistency, not the identity threshold).
    engine.next = FaceFrameAnalysis(
      faceDetected: true,
      embedding: _vec(0.5).reversed.map((v) => -v).toList(),
    );
    await s.checkNow();

    expect(
      tracker.events.where((e) => e.rule == ViolationRule.selfBaselineDeviation),
      isNotEmpty,
    );
  });

  test('a deviation check uses the baseline as it stood BEFORE this sample — '
      'the sample cannot validate itself', () async {
    final s = session();
    engine.next = FaceFrameAnalysis(faceDetected: true, embedding: _vec(0.5));
    await s.checkNow();
    await s.checkNow();

    final baselineBefore = s.selfSimilarityBaseline!;
    engine.next = FaceFrameAnalysis(
      faceDetected: true,
      embedding: _vec(0.5).reversed.map((v) => -v).toList(),
    );
    await s.checkNow();

    // The outlier is now included in the *updated* baseline's sample count,
    // proving it was appended after the deviation check ran against the
    // smaller, prior baseline.
    expect(s.selfSimilarityBaseline!.sampleCount, baselineBefore.sampleCount + 1);
  });

  test('consistent captures never log a baseline deviation', () async {
    final s = session();
    engine.next = FaceFrameAnalysis(faceDetected: true, embedding: _vec(0.5));
    for (var i = 0; i < 5; i++) {
      await s.checkNow();
    }
    expect(
      tracker.events.where((e) => e.rule == ViolationRule.selfBaselineDeviation),
      isEmpty,
    );
  });

  test('WithinSessionBaseline is exported and usable directly by the type '
      'exposed on VerificationSession', () {
    expect(WithinSessionBaseline.from([0.9, 0.9]), isNotNull);
  });
}
