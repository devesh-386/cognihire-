import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../integrity/integrity_tracker.dart';
import '../integrity/violation_rules.dart';
import 'face_engine.dart';
import 'identity_matcher.dart';
import 'verification_result.dart';
import 'within_session_baseline.dart';

/// Supplies the current camera frame as JPEG bytes, or null when no frame is
/// available (camera closed, not ready, permission denied).
typedef FrameGrabber = Future<Uint8List?> Function();

/// Drives continuous identity re-verification for the duration of a session.
///
/// This is the provenance signal: conventional proctoring verifies identity
/// once at login and then watches the *environment* for the rest of the
/// session. After that first check, a substitute or an assistant is invisible.
/// This class re-checks *who is producing the work*, repeatedly, and records
/// every attempt — including the ones that could not be performed.
///
/// Pure Dart on purpose: no Flutter imports, so the full state machine is
/// testable with a fake clock and a fake engine.
class VerificationSession {
  VerificationSession({
    required this.engine,
    required this.grabFrame,
    required this.tracker,
    List<double>? enrolledEmbedding,
    this.matcher = const IdentityMatcher(),
    this.baseInterval = const Duration(seconds: 20),
    this.jitter = const Duration(seconds: 5),
    Random? random,
  })  : _enrolled = enrolledEmbedding,
        _random = random ?? Random();

  final FaceEngine engine;
  final FrameGrabber grabFrame;
  final IntegrityTracker tracker;
  final IdentityMatcher matcher;

  /// Checks are spaced [baseInterval] ± [jitter]. A fixed period is trivially
  /// timeable by someone stepping out of frame between checks.
  final Duration baseInterval;
  final Duration jitter;

  final Random _random;
  List<double>? _enrolled;

  final _resultsController = StreamController<VerificationResult>.broadcast();

  /// Every verification attempt, including [Unchecked] ones.
  Stream<VerificationResult> get results => _resultsController.stream;

  /// Fires when consecutive mismatches reach the allowed limit.
  final _criticalController = StreamController<Mismatch>.broadcast();
  Stream<Mismatch> get onCritical => _criticalController.stream;

  int _consecutiveMismatches = 0;
  VerificationResult? _latest;
  Timer? _timer;
  bool _running = false;
  bool _checkInFlight = false;

  /// Raw cosine similarity of every *measured* attempt this session
  /// ([Unchecked] contributes nothing — there is no similarity to record).
  /// Reconstructed from the published rescaled similarity via the inverse of
  /// [IdentityMatcher.rescale] rather than computed a second time, so there is
  /// exactly one comparison per check.
  final List<double> _rawSimilaritySamples = [];

  VerificationResult? get latest => _latest;
  int get consecutiveMismatches => _consecutiveMismatches;
  bool get isRunning => _running;
  bool get hasEnrolledProfile => _enrolled != null && _enrolled!.isNotEmpty;

  /// The candidate's own self-similarity spread so far this session — null
  /// until at least two measured attempts have occurred. See
  /// [WithinSessionBaseline] for what this is and why it exists alongside the
  /// fixed enrolled-profile threshold rather than instead of it.
  WithinSessionBaseline? get selfSimilarityBaseline =>
      WithinSessionBaseline.from(_rawSimilaritySamples);

  /// Register the enrolled reference embedding captured during onboarding.
  void setEnrolledEmbedding(List<double> embedding) {
    _enrolled = List<double>.from(embedding);
  }

  /// Begin the loop. Runs one check immediately so the session does not spend
  /// its first 20 seconds unverified.
  Future<void> start() async {
    if (_running) return;
    _running = true;
    await checkNow();
    _scheduleNext();
  }

  void stop() {
    _running = false;
    _timer?.cancel();
    _timer = null;
  }

  Future<void> dispose() async {
    stop();
    await _resultsController.close();
    await _criticalController.close();
  }

  /// Next check delay: [baseInterval] ± [jitter], floored at 1s.
  /// Exposed for testing the jitter bounds.
  @visibleForTesting
  Duration nextDelay() {
    final jitterMs = jitter.inMilliseconds;
    final offset = jitterMs == 0 ? 0 : _random.nextInt(jitterMs * 2) - jitterMs;
    final ms = baseInterval.inMilliseconds + offset;
    return Duration(milliseconds: ms < 1000 ? 1000 : ms);
  }

  void _scheduleNext() {
    if (!_running) return;
    _timer?.cancel();
    _timer = Timer(nextDelay(), () async {
      await checkNow();
      _scheduleNext();
    });
  }

  /// Perform one verification attempt.
  ///
  /// Never throws and never returns a pass it did not measure: every failure
  /// path below produces an [Unchecked] carrying the reason.
  Future<VerificationResult> checkNow() async {
    if (_checkInFlight) {
      return _latest ??
          Unchecked(reason: UncheckedReason.noCamera, at: DateTime.now());
    }
    _checkInFlight = true;

    try {
      if (!hasEnrolledProfile) {
        return _publish(Unchecked(
          reason: UncheckedReason.noEnrolledProfile,
          at: DateTime.now(),
        ));
      }

      final Uint8List? frame;
      try {
        frame = await grabFrame();
      } catch (_) {
        return _publish(Unchecked(
          reason: UncheckedReason.noCamera,
          at: DateTime.now(),
        ));
      }

      if (frame == null || frame.isEmpty) {
        return _publish(Unchecked(
          reason: UncheckedReason.noCamera,
          at: DateTime.now(),
        ));
      }

      final FaceFrameAnalysis analysis;
      try {
        analysis = await engine.analyseFrame(frame);
      } on FaceEngineUnavailable {
        return _publish(Unchecked(
          reason: UncheckedReason.serviceUnreachable,
          at: DateTime.now(),
        ));
      } catch (_) {
        return _publish(Unchecked(
          reason: UncheckedReason.engineUnavailable,
          at: DateTime.now(),
        ));
      }

      if (!analysis.hasEmbedding) {
        return _publish(Unchecked(
          reason: analysis.faceDetected
              ? UncheckedReason.engineUnavailable
              : UncheckedReason.noFaceInFrame,
          at: DateTime.now(),
        ));
      }

      final result = matcher.compare(
        enrolled: _enrolled,
        live: analysis.embedding,
        consecutiveMismatches: _consecutiveMismatches,
      );
      return _publish(result);
    } finally {
      _checkInFlight = false;
    }
  }

  VerificationResult _publish(VerificationResult result) {
    _latest = result;

    switch (result) {
      case Verified():
        // A genuine match clears accumulated strikes.
        _consecutiveMismatches = 0;
        _checkSelfConsistency(result.similarity);

      case Mismatch(:final strike, :final similarity):
        _consecutiveMismatches = strike;
        tracker.log(
          ViolationRule.identityMismatch,
          detail: 'Live face matched enrolled profile at '
              '${IdentityMatcher.displayConfidence(similarity / 50 - 1).toStringAsFixed(1)}% '
              'confidence (strike $strike/${matcher.strikesAllowed})',
        );
        if (result.isCritical && !_criticalController.isClosed) {
          _criticalController.add(result);
        }
        _checkSelfConsistency(similarity);

      case Unchecked():
        // An interval the system could not measure is NOT a failure by the
        // candidate. Strikes are left untouched and nothing is logged against
        // them — but the attempt is still published so the gap is visible.
        break;
    }

    if (!_resultsController.isClosed) {
      _resultsController.add(result);
    }
    return result;
  }

  /// Checks [rescaledSimilarity] against the baseline established by *prior*
  /// attempts, then appends it to the sample history.
  ///
  /// Order matters: the check must run before the append, or a wildly
  /// deviant capture would help legitimise itself by being folded into the
  /// very baseline it is being compared against.
  void _checkSelfConsistency(double rescaledSimilarity) {
    final raw = rescaledSimilarity / 50 - 1;
    final priorBaseline = WithinSessionBaseline.from(_rawSimilaritySamples);

    if (priorBaseline != null && !priorBaseline.isConsistent(raw)) {
      tracker.log(
        ViolationRule.selfBaselineDeviation,
        detail: 'Similarity ${raw.toStringAsFixed(3)} fell outside this '
            "session's established range "
            '(mean ${priorBaseline.mean.toStringAsFixed(3)}, '
            'σ ${priorBaseline.std.toStringAsFixed(3)}).',
      );
    }

    _rawSimilaritySamples.add(raw);
  }
}
