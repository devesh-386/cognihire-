/// Renders a [ClaimAudit] into a self-contained document a reviewer can be
/// sent.
///
/// HTML rather than PDF, deliberately: it needs no dependency, opens in
/// anything, attaches to an email, and prints to PDF from any browser. The
/// stylesheet is inlined and no asset is fetched, so the file works offline and
/// forever — a record that stops rendering when a CDN moves is not a record.
///
/// What the document must preserve from the on-screen audit:
///   * every claim, including the ones never examined
///   * every identity attempt, including the ones that could not be performed
///   * the absence of a score, a ranking, or a recommendation
///
/// An export that quietly dropped the unmeasured attempts would read as a
/// cleaner session than the one that happened. So they are rendered, and the
/// counts at the top are computed from the same fields the screen uses.
library;

import '../claims/claim.dart';
import '../claims/claim_audit.dart';
import '../verification/verification_result.dart';

/// Escapes text for HTML.
///
/// Claim text is quoted from a candidate's resume — untrusted input that is
/// allowed to contain `<`, `&`, or anything else. Unescaped, a claim reading
/// `Wrote a <script> loader` would corrupt or execute in the reviewer's
/// browser. `&` is replaced first so the other replacements are not
/// double-escaped.
String escapeHtml(String raw) => raw
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');

String _formatTime(DateTime time) {
  final local = time.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
}

String _statusClass(ClaimStatus status) => switch (status) {
      ClaimStatus.substantiated => 'substantiated',
      ClaimStatus.notDemonstrated => 'not-demonstrated',
      ClaimStatus.contradicted => 'contradicted',
      ClaimStatus.notExamined => 'not-examined',
    };

String _evidenceLabel(EvidenceKind kind) => switch (kind) {
      EvidenceKind.probeResponse => 'Probe response',
      EvidenceKind.processSignal => 'Process signal',
      EvidenceKind.identityCheck => 'Identity check',
    };

String _provenanceStatement(ClaimAudit audit) => switch (audit.provenanceQuality) {
      ProvenanceQuality.solid =>
        'Identity was confirmed throughout the session '
            '(${audit.identityChecksPerformed} checks, all matched).',
      ProvenanceQuality.disputed =>
        'Identity did not match on '
            '${audit.identityChecksPerformed - audit.identityChecksVerified} of '
            '${audit.identityChecksPerformed} checks. Review before relying on '
            'this session.',
      ProvenanceQuality.sparse =>
        'Identity checks were mostly unavailable '
            '(${audit.identityChecksPerformed} of '
            '${audit.identityAttempts.length} attempts succeeded). Provenance '
            'evidence is incomplete.',
      ProvenanceQuality.none =>
        'Identity could not be verified during this session. No provenance '
            'evidence is available.',
    };

String _provenanceClass(ProvenanceQuality quality) => switch (quality) {
      ProvenanceQuality.solid => 'solid',
      ProvenanceQuality.disputed => 'disputed',
      ProvenanceQuality.sparse => 'sparse',
      ProvenanceQuality.none => 'none',
    };

/// One row per identity attempt.
///
/// [Unchecked] rows carry the reason and an explicit em-dash where a similarity
/// would go — never a blank cell, which reads as zero, and never a number,
/// because none was measured.
String _attemptRow(VerificationResult attempt) {
  final (outcome, detail, rowClass) = switch (attempt) {
    Verified(:final similarity) => (
        'Verified',
        similarity.toStringAsFixed(1),
        'verified',
      ),
    Mismatch(:final similarity, :final strike, :final strikesAllowed) => (
        'Mismatch (strike $strike of $strikesAllowed)',
        similarity.toStringAsFixed(1),
        'mismatch',
      ),
    Unchecked(:final reason) => (
        'Not checked',
        '&mdash;',
        'unchecked',
      ),
  };

  final note = attempt is Unchecked ? escapeHtml(attempt.reason.message) : '';

  return '''
        <tr class="$rowClass">
          <td>${escapeHtml(_formatTime(attempt.at))}</td>
          <td>${escapeHtml(outcome)}</td>
          <td class="num">$detail</td>
          <td>$note</td>
        </tr>''';
}

String _findingSection(ClaimFinding finding) {
  final evidence = finding.evidence.isEmpty
      ? '          <p class="no-evidence">No evidence was recorded for this '
          'claim during the session.</p>'
      : '''
          <table class="evidence">
            <thead>
              <tr><th>Time</th><th>Kind</th><th>Observation</th></tr>
            </thead>
            <tbody>
${finding.evidence.map((e) => '''              <tr>
                <td>${escapeHtml(_formatTime(e.at))}</td>
                <td>${escapeHtml(_evidenceLabel(e.kind))}</td>
                <td>${escapeHtml(e.observation)}</td>
              </tr>''').join('\n')}
            </tbody>
          </table>''';

  final skill = finding.claim.skill;

  return '''
        <section class="finding ${_statusClass(finding.status)}">
          <div class="finding-head">
            <blockquote>${escapeHtml(finding.claim.text)}</blockquote>
            <span class="badge">${escapeHtml(finding.status.label)}</span>
          </div>
          <p class="meta">Source: ${escapeHtml(finding.claim.source)}${skill == null ? '' : ' &middot; Skill: ${escapeHtml(skill)}'}</p>
          <p class="status-desc">${escapeHtml(finding.status.description)}</p>
$evidence
        </section>''';
}

/// Renders the complete document.
String renderAuditHtml(
  ClaimAudit audit, {
  required String label,
  required DateTime generatedAt,
}) {
  final counts = <ClaimStatus, int>{
    for (final status in ClaimStatus.values)
      status: audit.byStatus(status).length,
  };

  final attempts = audit.identityAttempts.isEmpty
      ? '      <p class="no-evidence">No identity verification was attempted '
          'during this session.</p>'
      : '''
      <table class="attempts">
        <thead>
          <tr><th>Time</th><th>Outcome</th><th>Similarity</th><th>Note</th></tr>
        </thead>
        <tbody>
${audit.identityAttempts.map(_attemptRow).join('\n')}
        </tbody>
      </table>''';

  return '''<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Claim audit &mdash; ${escapeHtml(label)}</title>
<style>
  :root { color-scheme: light; }
  body {
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    max-width: 60rem; margin: 0 auto; padding: 2rem 1.5rem 4rem;
    color: #1a1a1a; background: #fff; line-height: 1.5;
  }
  h1 { font-size: 1.6rem; margin: 0 0 .25rem; }
  h2 { font-size: 1.1rem; margin: 2.5rem 0 .5rem; }
  .sub { color: #555; margin: 0 0 1.5rem; font-size: .9rem; }
  .summary {
    border: 1px solid #ddd; border-radius: 8px; padding: 1rem 1.25rem;
    background: #fafafa;
  }
  .provenance {
    margin-top: .75rem; padding: .75rem 1rem; border-radius: 6px;
    border-left: 4px solid #999; background: #f4f4f4; font-size: .9rem;
  }
  .provenance.solid { border-left-color: #2e7d32; background: #f1f8f2; }
  .provenance.disputed { border-left-color: #c62828; background: #fdf2f2; }
  .provenance.sparse, .provenance.none {
    border-left-color: #ef6c00; background: #fff8f0;
  }
  .tally { display: flex; flex-wrap: wrap; gap: 1.25rem; margin-top: .75rem;
           font-size: .85rem; }
  .tally span { color: #555; }
  .tally b { color: #1a1a1a; }
  .finding {
    border: 1px solid #e2e2e2; border-radius: 8px;
    padding: 1rem 1.25rem; margin-bottom: 1rem;
  }
  .finding-head {
    display: flex; gap: 1rem; align-items: flex-start;
    justify-content: space-between;
  }
  blockquote {
    margin: 0; font-style: italic; font-size: 1.02rem; flex: 1;
  }
  .badge {
    font-size: .72rem; font-weight: 700; text-transform: uppercase;
    letter-spacing: .04em; padding: .25rem .6rem; border-radius: 999px;
    white-space: nowrap; background: #eee; color: #444;
  }
  .substantiated .badge { background: #e6f4ea; color: #1e6b2c; }
  .not-demonstrated .badge { background: #fff2e0; color: #a65100; }
  .contradicted .badge { background: #fdecea; color: #b3261e; }
  .not-examined .badge { background: #eeeeee; color: #5f6368; }
  .meta, .status-desc { font-size: .85rem; color: #555; margin: .5rem 0 0; }
  .no-evidence { font-size: .85rem; color: #777; font-style: italic;
                 margin: .75rem 0 0; }
  table { border-collapse: collapse; width: 100%; margin-top: .75rem;
          font-size: .85rem; }
  th, td { text-align: left; padding: .4rem .6rem; border-bottom: 1px solid #eee;
           vertical-align: top; }
  th { font-weight: 600; color: #555; background: #fafafa; }
  td.num { text-align: right; font-variant-numeric: tabular-nums; }
  tr.unchecked td { color: #8a6d3b; background: #fffdf5; }
  tr.mismatch td { color: #b3261e; background: #fdf6f6; }
  .notice {
    margin-top: 2.5rem; padding: 1rem 1.25rem; border-radius: 8px;
    background: #f4f4f6; font-size: .88rem; color: #333;
  }
  footer { margin-top: 2rem; font-size: .75rem; color: #777;
           border-top: 1px solid #eee; padding-top: 1rem; }
  @media print {
    body { padding: 0; max-width: none; }
    .finding, .summary { break-inside: avoid; }
  }
</style>
</head>
<body>
  <h1>Claim audit</h1>
  <p class="sub">${escapeHtml(label)} &middot; generated ${escapeHtml(_formatTime(generatedAt))}</p>

  <div class="summary">
    <strong>${escapeHtml(audit.summary)}</strong>
    <div class="provenance ${_provenanceClass(audit.provenanceQuality)}">
      ${escapeHtml(_provenanceStatement(audit))}
    </div>
    <div class="tally">
      <span>Session start <b>${escapeHtml(_formatTime(audit.sessionStart))}</b></span>
      <span>Session end <b>${escapeHtml(_formatTime(audit.sessionEnd))}</b></span>
      <span>Duration <b>${audit.sessionEnd.difference(audit.sessionStart).inMinutes} min</b></span>
    </div>
    <div class="tally">
${ClaimStatus.values.map((s) => '      <span>${escapeHtml(s.label)} <b>${counts[s]}</b></span>').join('\n')}
    </div>
  </div>

  <h2>Claims</h2>
  <p class="sub">Each claim is reported on its own evidence. Claims are not combined into a score.</p>
${audit.findings.map(_findingSection).join('\n')}

  <h2>Identity verification log</h2>
  <p class="sub">Every attempt, including the ones that could not be performed.</p>
$attempts

  <div class="notice">
    This record does not contain a hiring recommendation and no candidate is
    filtered automatically. It reports which claims were examined, what was
    observed, and what could not be checked. The decision is the reviewer&#39;s.
  </div>

  <footer>
    Generated by CogniHire. Contains no score, no ranking, and no inferred
    demographic or emotional attribute. Identity similarity is a cosine
    comparison against a reference face captured at enrolment; entries marked
    &ldquo;Not checked&rdquo; were not measured and must not be read as passes.
  </footer>
</body>
</html>
''';
}
