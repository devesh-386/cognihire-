import 'package:cognihire/core/integrity/integrity_tracker.dart';
import 'package:cognihire/core/integrity/violation_rules.dart';
import 'package:cognihire/core/verification/identity_matcher.dart';
import 'package:cognihire/core/verification/verification_result.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('IntegrityTracker', () {
    test('counts repeats without turning them into a penalty', () {
      final tracker = IntegrityTracker();
      final first = tracker.log(ViolationRule.identityMismatch);
      final second = tracker.log(ViolationRule.identityMismatch);
      final third = tracker.log(ViolationRule.identityMismatch);

      // The ordinal is a reportable fact; there is no impact number to escalate.
      expect(first.occurrenceIndex, 1);
      expect(second.occurrenceIndex, 2);
      expect(third.occurrenceIndex, 3);
      expect(tracker.occurrencesOf(ViolationRule.identityMismatch), 3);
    });

    test('exposes no aggregate score — measurement, not verdict', () {
      // The class deliberately has no `score`, `riskScore`, `summarise`, or any
      // summed number. Observations are logged, never totalled. If this ever
      // fails to compile because such a member returned, the philosophy
      // regression is the bug, not this test.
      final tracker = IntegrityTracker();
      tracker.log(ViolationRule.additionalPerson);
      tracker.log(ViolationRule.focusLoss);
      expect(tracker.events.length, 2);
    });

    test('keeps observations ordered most-recent-first', () {
      final tracker = IntegrityTracker();
      tracker.log(ViolationRule.focusLoss);
      tracker.log(ViolationRule.identityMismatch);
      expect(tracker.events.first.rule, ViolationRule.identityMismatch);
      expect(tracker.events.last.rule, ViolationRule.focusLoss);
    });
  });

  group('IdentityMatcher', () {
    const matcher = IdentityMatcher();

    List<double> vec(double seed, int len) =>
        List.generate(len, (i) => seed + i * 0.001);

    test('missing enrolled profile is Unchecked, never a pass', () {
      final result = matcher.compare(
        enrolled: null,
        live: vec(0.5, 512),
        consecutiveMismatches: 0,
      );

      expect(result, isA<Unchecked>());
      expect((result as Unchecked).reason, UncheckedReason.noEnrolledProfile);
      // The regression that matters: absence of data must not read as success.
      expect(result.isVerified, isFalse);
      expect(result.didMeasure, isFalse);
    });

    test('no face in frame is Unchecked, never a mismatch', () {
      final result = matcher.compare(
        enrolled: vec(0.5, 512),
        live: const [],
        consecutiveMismatches: 0,
      );

      expect(result, isA<Unchecked>());
      // Not penalised either — the system failed to look, the candidate
      // did not fail a check.
      expect(result.didMeasure, isFalse);
    });

    test('mismatched embedding lengths are Unchecked, not scored', () {
      final result = matcher.compare(
        enrolled: vec(0.5, 512),
        live: vec(0.5, 128),
        consecutiveMismatches: 0,
      );
      expect(result, isA<Unchecked>());
    });

    test('identical embeddings verify', () {
      final e = vec(0.5, 512);
      final result = matcher.compare(
        enrolled: e,
        live: List<double>.from(e),
        consecutiveMismatches: 0,
      );

      expect(result, isA<Verified>());
      expect((result as Verified).similarity, closeTo(100, 0.01));
    });

    test('orthogonal embeddings mismatch and accrue a strike', () {
      // Orthogonal vectors == unrelated faces (raw cosine ~0).
      final enrolled = [1.0, 0.0, 1.0, 0.0];
      final live = [0.0, 1.0, 0.0, 1.0];

      final result = matcher.compare(
        enrolled: enrolled,
        live: live,
        consecutiveMismatches: 1,
      );

      expect(result, isA<Mismatch>());
      final m = result as Mismatch;
      expect(m.strike, 2);
      expect(m.isCritical, isFalse);
      // Documents the trap: an unrelated face scores ~50 on the legacy scale.
      expect(m.similarity, closeTo(50, 0.01));
    });

    test('third consecutive mismatch is critical', () {
      final result = matcher.compare(
        enrolled: [1.0, 0.0],
        live: [0.0, 1.0],
        consecutiveMismatches: 2,
      );
      expect((result as Mismatch).isCritical, isTrue);
    });

    test('displayConfidence reports unrelated faces near zero', () {
      // The legacy scale calls an unrelated face 50%; that misleads a reader.
      expect(IdentityMatcher.rescale(0.0), closeTo(50, 0.01));
      expect(IdentityMatcher.displayConfidence(0.0), closeTo(0, 0.01));
      expect(IdentityMatcher.displayConfidence(1.0), closeTo(100, 0.01));
    });

    test('threshold sits clear of the measured impostor baseline', () {
      // Measured on buffalo_l: two different people scored raw cosine 0.012.
      const impostorBaseline = 0.012;
      expect(matcher.rawThreshold, greaterThan(impostorBaseline * 10));
      // And below the legacy 0.70 bar that would reject genuine candidates.
      expect(matcher.rawThreshold, lessThan(0.70));
    });
  });
}
