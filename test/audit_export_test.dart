import 'package:cognihire/core/claims/claim.dart';
import 'package:cognihire/core/claims/claim_audit.dart';
import 'package:cognihire/core/export/audit_export.dart';
import 'package:cognihire/core/verification/verification_result.dart';
import 'package:flutter_test/flutter_test.dart';

ClaimAudit _audit({
  List<Claim>? claims,
  Map<String, List<ClaimEvidence>>? evidence,
  Map<String, ClaimStatus>? assessments,
  List<VerificationResult>? attempts,
}) {
  final start = DateTime.utc(2026, 7, 27, 9);

  return const ClaimAuditBuilder().build(
    claims: claims ??
        const [
          Claim(
            id: 'c1',
            text: 'Built a React dashboard',
            source: 'Resume, page 1',
            skill: 'React',
          ),
          Claim(id: 'c2', text: 'Led a CI migration', source: 'Cover letter'),
        ],
    evidenceByClaimId: evidence ??
        {
          'c1': [
            ClaimEvidence(
              observation: 'Described state lifting when asked.',
              kind: EvidenceKind.probeResponse,
              at: start.add(const Duration(minutes: 6)),
            ),
          ],
        },
    reviewerAssessments: assessments ?? const {'c1': ClaimStatus.substantiated},
    identityAttempts: attempts ??
        [
          Verified(similarity: 96.4, at: start.add(const Duration(minutes: 1))),
          Unchecked(
            reason: UncheckedReason.noFaceInFrame,
            at: start.add(const Duration(minutes: 15)),
          ),
        ],
    sessionStart: start,
    sessionEnd: start.add(const Duration(minutes: 38)),
  );
}

String _render(ClaimAudit audit, {String label = 'Alice'}) => renderAuditHtml(
      audit,
      label: label,
      generatedAt: DateTime.utc(2026, 7, 27, 12),
    );

void main() {
  group('escapeHtml', () {
    test('escapes the characters that would break or execute', () {
      expect(
        escapeHtml('<script>alert("x")</script>'),
        '&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt;',
      );
    });

    test('escapes ampersands first so nothing is double-escaped', () {
      expect(escapeHtml('a & b < c'), 'a &amp; b &lt; c');
      expect(escapeHtml('&lt;'), '&amp;lt;');
    });

    test('leaves ordinary text alone', () {
      expect(escapeHtml('Optimised Postgres queries'),
          'Optimised Postgres queries');
    });
  });

  group('rendered document', () {
    test('is a complete standalone HTML document', () {
      final html = _render(_audit());

      expect(html, startsWith('<!DOCTYPE html>'));
      expect(html.trimRight(), endsWith('</html>'));
      expect(html, contains('<style>'));
    });

    test('fetches nothing from the network', () {
      final html = _render(_audit());

      expect(html, isNot(contains('http://')));
      expect(html, isNot(contains('https://')));
      expect(html, isNot(contains('<script')));
    });

    test('includes every claim, examined or not', () {
      final html = _render(_audit());

      expect(html, contains('Built a React dashboard'));
      expect(html, contains('Led a CI migration'));
      expect(html, contains('Substantiated'));
      expect(html, contains('Not examined'));
    });

    test('carries the session summary verbatim', () {
      final audit = _audit();
      expect(_render(audit), contains(escapeHtml(audit.summary)));
    });

    test('states the label and the generation time', () {
      final html = _render(_audit(), label: 'Alice Nguyen');

      expect(html, contains('Alice Nguyen'));
      expect(html, contains('2026-07-27'));
    });
  });

  group('untrusted claim text cannot break the document', () {
    test('a claim containing markup is escaped, not embedded', () {
      final html = _render(_audit(
        claims: const [
          Claim(
            id: 'c1',
            text: 'Wrote a <script>alert(1)</script> loader',
            source: 'Resume',
          ),
        ],
        evidence: const {},
        assessments: const {},
      ));

      expect(html, isNot(contains('<script>alert(1)</script>')));
      expect(html, contains('&lt;script&gt;alert(1)&lt;/script&gt;'));
    });

    test('markup in an evidence observation is escaped', () {
      final html = _render(_audit(
        evidence: {
          'c1': [
            ClaimEvidence(
              observation: 'Pasted <img src=x onerror=alert(1)> into the box',
              kind: EvidenceKind.processSignal,
              at: DateTime.utc(2026, 7, 27, 9, 20),
            ),
          ],
        },
      ));

      expect(html, isNot(contains('<img src=x')));
      expect(html, contains('&lt;img src=x'));
    });

    test('markup in the session label is escaped', () {
      final html = _render(_audit(), label: '<b>Alice</b>');

      expect(html, isNot(contains('<b>Alice</b>')));
      expect(html, contains('&lt;b&gt;Alice&lt;/b&gt;'));
    });
  });

  group('unmeasured checks survive into the export', () {
    test('an unchecked attempt is listed with its reason', () {
      final html = _render(_audit());

      expect(html, contains('Not checked'));
      expect(html, contains('No face detected in frame'));
    });

    test('an unchecked attempt shows a dash, never a number', () {
      final html = _render(_audit(
        attempts: [
          Unchecked(
            reason: UncheckedReason.serviceUnreachable,
            at: DateTime.utc(2026, 7, 27, 9, 5),
          ),
        ],
      ));

      expect(html, contains('&mdash;'));
      expect(html, contains('Verification service unreachable'));
      // The only similarity-shaped content would be a fabricated one.
      expect(html, isNot(contains('0.0')));
      expect(html, isNot(contains('100.0')));
    });

    test('a mismatch reports its strike count', () {
      final html = _render(_audit(
        attempts: [
          Mismatch(
            similarity: 41.2,
            strike: 2,
            strikesAllowed: 3,
            at: DateTime.utc(2026, 7, 27, 9, 5),
          ),
        ],
      ));

      expect(html, contains('Mismatch (strike 2 of 3)'));
      expect(html, contains('41.2'));
    });

    test('a session with no attempts says so instead of showing an empty table',
        () {
      final html = _render(_audit(attempts: const []));

      expect(html, contains('No identity verification was attempted'));
      expect(html, contains('Identity could not be verified'));
    });
  });

  group('the export makes no recommendation', () {
    test('carries the no-decision notice', () {
      final html = _render(_audit());

      expect(html, contains('does not contain a hiring recommendation'));
      expect(html, contains('no candidate is\n    filtered automatically'));
    });

    test('contains no hire/reject language and no aggregate score', () {
      final html = _render(_audit()).toLowerCase();

      expect(html, isNot(contains('recommend hiring')));
      expect(html, isNot(contains('do not hire')));
      expect(html, isNot(contains('overall score')));
      expect(html, isNot(contains('total score')));
      expect(html, isNot(contains('composite')));
      // "no ranking" appears in the footer disclaimer, so assert on the shape a
      // real ranking would take rather than on the word itself.
      expect(html, isNot(contains('ranked')));
      expect(html, isNot(contains('rank:')));
      expect(html, isNot(contains('percentile')));
    });
  });
}
