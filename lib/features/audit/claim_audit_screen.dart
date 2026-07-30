import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/claims/claim.dart';
import '../../core/claims/claim_audit.dart';
import '../../core/design/app_theme.dart';
import '../../core/export/audit_export.dart';
import '../../core/export/export_writer.dart';
import '../../core/graph/graph_from_audit.dart';
import '../../core/ml/decision_from_audit.dart';
import '../../core/ml/sufficiency_model.dart';
import '../../core/ml/synthetic_sufficiency_dataset.dart';
import '../graph/evidence_graph_screen.dart';
import '../reviewer/model_decision_screen.dart';

/// The reviewer-facing output of a session.
///
/// Reads as a record, not a verdict. There is no overall score, no ranking, and
/// no recommended action anywhere on this screen — the reviewer decides, and
/// this gives them what they need to decide with.
class ClaimAuditScreen extends StatelessWidget {
  const ClaimAuditScreen({
    super.key,
    required this.audit,
    this.label = 'Unlabelled session',
  });

  final ClaimAudit audit;

  /// Shown in the exported document so a reviewer knows whose session it is.
  final String label;

  String _filename() {
    final safe = label
        .replaceAll(RegExp(r'[^A-Za-z0-9 _-]'), '')
        .trim()
        .replaceAll(RegExp(r'\s+'), '-')
        .toLowerCase();
    final stamp = audit.sessionEnd.toIso8601String().substring(0, 19)
        .replaceAll(':', '');
    return 'claim-audit-${safe.isEmpty ? 'session' : safe}-$stamp.html';
  }

  /// Writes the audit next to where the reviewer can pick it up, and reports
  /// exactly where it went. A failure says so — an export that silently does
  /// nothing would leave someone believing HR had received a document.
  Future<void> _export(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final html = renderAuditHtml(
      audit,
      label: label,
      generatedAt: DateTime.now(),
    );

    try {
      final path = await writeAuditExport(html, filename: _filename());
      messenger.showSnackBar(SnackBar(
        duration: const Duration(seconds: 10),
        content: Text('Audit exported to $path'),
        action: SnackBarAction(
          label: 'Copy path',
          onPressed: () => Clipboard.setData(ClipboardData(text: path)),
        ),
      ));
    } catch (error) {
      messenger.showSnackBar(SnackBar(
        backgroundColor: Colors.red.shade800,
        duration: const Duration(seconds: 8),
        content: Text('Export failed: $error'),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Claim audit'),
        actions: [
          TextButton.icon(
            onPressed: () => _openModelDecision(context),
            icon: const Icon(Icons.calculate_outlined, size: 18),
            label: const Text('Model view'),
          ),
          if (exportSupported)
            TextButton.icon(
              onPressed: () => _export(context),
              icon: const Icon(Icons.download_outlined, size: 18),
              label: const Text('Export'),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Session record', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 6),
                  Text(audit.summary, style: theme.textTheme.bodyMedium),
                  const SizedBox(height: 12),
                  _provenanceBanner(context),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          Text('Claims', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'Each claim is reported on its own evidence. Claims are not '
            'combined into a score.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          for (final finding in audit.findings) _findingCard(context, finding),
          const SizedBox(height: 24),
          _decisionNotice(context),
        ],
      ),
    );
  }

  Widget _provenanceBanner(BuildContext context) {
    final evidence = context.evidence;
    final (Color colour, IconData icon, String text) =
        switch (audit.provenanceQuality) {
      ProvenanceQuality.solid => (
          evidence.verified,
          Icons.verified_user,
          'Identity was confirmed throughout the session '
              '(${audit.identityChecksPerformed} checks, all matched).',
        ),
      ProvenanceQuality.disputed => (
          evidence.disputed,
          Icons.gpp_maybe,
          'Identity did not match on '
              '${audit.identityChecksPerformed - audit.identityChecksVerified} '
              'of ${audit.identityChecksPerformed} checks. Review before '
              'relying on this session.',
        ),
      ProvenanceQuality.sparse => (
          evidence.unmeasured,
          Icons.help_outline,
          'Identity checks were mostly unavailable '
              '(${audit.identityChecksPerformed} of '
              '${audit.identityAttempts.length} attempts succeeded). '
              'Provenance evidence is incomplete.',
        ),
      ProvenanceQuality.none => (
          evidence.unmeasured,
          Icons.help_outline,
          'Identity could not be verified during this session. '
              'No provenance evidence is available.',
        ),
    };

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.08),
        border: Border.all(color: colour.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: colour, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text, style: Theme.of(context).textTheme.bodySmall),
          ),
        ],
      ),
    );
  }

  Widget _findingCard(BuildContext context, ClaimFinding finding) {
    final theme = Theme.of(context);
    final colour = switch (finding.status) {
      ClaimStatus.substantiated => context.evidence.verified,
      ClaimStatus.notDemonstrated => context.evidence.unmeasured,
      ClaimStatus.contradicted => context.evidence.disputed,
      ClaimStatus.notExamined => context.evidence.notExamined,
    };

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    '"${finding.claim.text}"',
                    style: theme.textTheme.bodyLarge
                        ?.copyWith(fontStyle: FontStyle.italic),
                  ),
                ),
                const SizedBox(width: 10),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: colour.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    finding.status.label,
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: colour, fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text('Source: ${finding.claim.source}',
                style: theme.textTheme.bodySmall),
            const SizedBox(height: 8),
            Text(finding.status.description,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            if (finding.evidence.isNotEmpty) ...[
              const Divider(height: 20),
              Text('Evidence', style: theme.textTheme.labelMedium),
              const SizedBox(height: 6),
              for (final e in finding.evidence)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(_evidenceIcon(e.kind),
                          size: 14, color: theme.colorScheme.onSurfaceVariant),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(e.observation,
                            style: theme.textTheme.bodySmall),
                      ),
                    ],
                  ),
                ),
            ],
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: () => _openGraph(context, finding),
                icon: const Icon(Icons.hub_outlined, size: 16),
                label: const Text('View evidence graph'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Opens the graph view for one claim.
  ///
  /// Derived on demand from this audit rather than stored alongside it — the
  /// audit stays the single source of truth for what happened, and the graph
  /// is a view over it that can never drift out of sync with what it depicts.
  void _openGraph(BuildContext context, ClaimFinding finding) {
    final graph = graphForClaim(audit, finding.claim.id);
    if (graph == null) return;

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => EvidenceGraphScreen(
          graph: graph,
          claimText: finding.claim.text,
        ),
      ),
    );
  }

  /// Opens the model's view of this session.
  ///
  /// Fits the sufficiency model on synthetic data at open time — which is the
  /// honest thing to do while no real trained model exists, and is why the
  /// destination screen shows a caveat and refuses to be framed as a finding
  /// about a person. The features are real; the weights are not.
  void _openModelDecision(BuildContext context) {
    final model = SufficiencyModel.fitSynthetic(
      const SyntheticSufficiencyGenerator().generate(count: 400, seed: 1),
    );
    final decision = buildDecisionFromAudit(
      audit,
      graphs: graphsFromAudit(audit),
      model: model,
    );

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ModelDecisionScreen(
          decision: decision,
          claimText: '${audit.findings.length} claim(s) in this session',
        ),
      ),
    );
  }

  static IconData _evidenceIcon(EvidenceKind kind) => switch (kind) {
        EvidenceKind.probeResponse => Icons.forum_outlined,
        EvidenceKind.processSignal => Icons.timeline,
        EvidenceKind.identityCheck => Icons.face_outlined,
      };

  Widget _decisionNotice(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline,
              size: 18, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'This record does not contain a hiring recommendation and no '
              'candidate is filtered automatically. It reports which claims '
              'were examined, what was observed, and what could not be '
              'checked. The decision is yours.',
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}
