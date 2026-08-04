/// Reports: turn stored sessions into a document somebody else can read.
///
/// ## Why this exists as its own destination
///
/// The mockup had a "Reports" nav item and an "Invite Team" button, neither of
/// which had anything behind them. Both point at the same real need: the audit is
/// only useful if it can leave this machine and survive being read by a person who
/// was not in the room — a hiring manager, a compliance reviewer, the candidate.
///
/// This app has no server and no accounts, so "invite" is not a thing it can do.
/// What it can do is write a self-contained HTML document per session, which is
/// what a reviewer actually needs: openable anywhere, printable, and not dependent
/// on this app still existing. That is what this screen does, and it is why the
/// mockup's button was renamed rather than stubbed.
library;

import 'package:flutter/material.dart';

import '../../core/claims/claim.dart';
import '../../core/design/app_theme.dart';
import '../../core/export/audit_export.dart';
import '../../core/export/export_writer.dart';
import '../../core/persistence/audit_store.dart';
import '../../core/workspace/workspace_loader.dart';
import '../../core/workspace/workspace_stats.dart';
import '../../ui/app_shell.dart';
import '../../ui/components.dart';
import '../../ui/patterns.dart';
import '../common/empty_state.dart';

class ReportsScreen extends StatefulWidget {
  const ReportsScreen({
    super.key,
    required this.store,
    required this.sampleAudit,
    this.onStartSession,
  });

  final AuditStore store;

  /// The illustrative audit, offered here as an example of what an export looks
  /// like. Always labelled as sample data.
  final Widget Function() sampleAudit;

  final VoidCallback? onStartSession;

  @override
  State<ReportsScreen> createState() => ReportsScreenState();
}

class ReportsScreenState extends State<ReportsScreen> {
  WorkspaceSnapshot? _snapshot;
  bool _loading = true;

  /// Ids currently being written, so each row can show its own progress rather
  /// than the whole screen locking.
  final Set<String> _busy = {};

  @override
  void initState() {
    super.initState();
    reload();
  }

  Future<void> reload() async {
    setState(() => _loading = true);
    final snapshot = await loadWorkspace(widget.store);
    if (!mounted) return;
    setState(() {
      _snapshot = snapshot;
      _loading = false;
    });
  }

  static String _filename(SessionRecord record) {
    final safe = record.label
        .replaceAll(RegExp(r'[^A-Za-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    final stamp = record.audit.sessionEnd
        .toIso8601String()
        .substring(0, 19)
        .replaceAll(RegExp('[:-]'), '');
    return 'cognihire-${safe.isEmpty ? 'session' : safe}-$stamp.html';
  }

  Future<String?> _write(SessionRecord record) async {
    final html = renderAuditHtml(
      record.audit,
      label: record.label,
      generatedAt: DateTime.now(),
    );
    return writeAuditExport(html, filename: _filename(record));
  }

  Future<void> _exportOne(SessionRecord record) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy.add(record.id));
    try {
      final path = await _write(record);
      messenger.showSnackBar(SnackBar(
        duration: const Duration(seconds: 8),
        content: Text('Written to $path'),
      ));
    } catch (error) {
      messenger.showSnackBar(SnackBar(
        duration: const Duration(seconds: 8),
        content: Text('Export failed: $error'),
      ));
    } finally {
      if (mounted) setState(() => _busy.remove(record.id));
    }
  }

  Future<void> _exportAll() async {
    final snapshot = _snapshot;
    if (snapshot == null || snapshot.records.isEmpty) return;

    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy.addAll(snapshot.records.map((r) => r.id)));

    var written = 0;
    final failures = <String>[];
    String? lastPath;

    for (final record in snapshot.records) {
      try {
        lastPath = await _write(record);
        written++;
      } catch (error) {
        failures.add('${record.label}: $error');
      }
    }

    if (!mounted) return;
    setState(() => _busy.clear());

    // Reports both halves. A partial success reported as success is the same
    // class of error as a fabricated pass.
    messenger.showSnackBar(SnackBar(
      duration: const Duration(seconds: 10),
      content: Text(
        failures.isEmpty
            ? 'Wrote $written file(s) alongside $lastPath'
            : 'Wrote $written file(s); ${failures.length} failed — '
                '${failures.first}',
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final snapshot = _snapshot;
    final records = snapshot?.records ?? const <SessionRecord>[];

    return ShellPage(
      title: 'Reports',
      subtitle: 'Each export is one self-contained HTML file: the claims, the '
          'evidence behind each one, every identity check including the ones '
          'that could not be performed, and what was never examined.',
      actions: [
        IconButton(
          onPressed: _loading ? null : reload,
          tooltip: 'Refresh',
          icon: const Icon(Icons.refresh, size: 20),
        ),
        FilledButton.icon(
          onPressed: records.isEmpty || _busy.isNotEmpty ? null : _exportAll,
          icon: const Icon(Icons.download_outlined, size: 18),
          label: Text(
            records.isEmpty ? 'Nothing to export' : 'Export all ${records.length}',
          ),
        ),
      ],
      children: [
        if (_loading && snapshot == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: Spacing.hero),
            child: Center(child: CircularProgressIndicator()),
          )
        else ...[
          _whatsInside(context, snapshot),
          const SizedBox(height: Spacing.section),
          if (records.isEmpty)
            EmptyState(
              icon: Icons.description_outlined,
              title: 'No sessions to report on',
              body: 'Exports are generated from stored sessions. The sample '
                  'audit below shows the shape of one.',
              actionLabel:
                  widget.onStartSession == null ? null : 'Start a session',
              onAction: widget.onStartSession,
            )
          else
            SectionCard(
              title: 'Stored sessions',
              icon: Icons.folder_open_outlined,
              description: 'Newest first.',
              child: Column(
                children: [
                  for (final record in records)
                    RecordRow(
                      leading: Monogram(name: record.label, diameter: 34),
                      title: record.label,
                      subtitle: '${_stamp(record.audit.sessionEnd)} · '
                          '${record.audit.summary}',
                      trailing: _busy.contains(record.id)
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : IconButton(
                              onPressed: () => _exportOne(record),
                              tooltip: 'Export as HTML',
                              icon: const Icon(
                                Icons.download_outlined,
                                size: 18,
                              ),
                            ),
                    ),
                ],
              ),
            ),
          const SizedBox(height: Spacing.section),
          SectionCard(
            title: 'Sample audit',
            icon: Icons.science_outlined,
            description: 'Illustrative data, not a real candidate. Included so '
                'the report format can be reviewed before anyone sits a '
                'session.',
            child: Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => widget.sampleAudit()),
                ),
                icon: const Icon(Icons.open_in_new, size: 18),
                label: const Text('Open the sample audit'),
              ),
            ),
          ),
          const SizedBox(height: Spacing.xl),
          Text(
            'Exports are written to your Downloads folder where the platform '
            'has one. Nothing is uploaded anywhere by this app.',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ],
    );
  }

  Widget _whatsInside(BuildContext context, WorkspaceSnapshot? snapshot) {
    final stats = snapshot?.stats ?? WorkspaceStats.empty();

    return MetricStrip(
      children: [
        MetricCard(
          label: 'Reportable sessions',
          value: '${stats.sessions}',
          icon: Icons.event_note_outlined,
          qualifier: stats.unreadableSessions == 0
              ? 'All stored sessions could be read'
              : '${stats.unreadableSessions} could not be read and cannot be '
                  'exported',
          tone: stats.unreadableSessions == 0
              ? null
              : Theme.of(context).colorScheme.error,
        ),
        MetricCard(
          label: 'Claims covered',
          value: '${stats.claimsTotal}',
          icon: Icons.list_alt_outlined,
          qualifier: '${stats.claimsExamined} examined, '
              '${stats.statusCount(ClaimStatus.notExamined)} explicitly not',
        ),
        MetricCard(
          label: 'Evidence items',
          value: '${stats.evidenceItems}',
          icon: Icons.description_outlined,
          qualifier: 'Each one appears in the export with its timestamp and '
              'kind',
        ),
        MetricCard(
          label: 'Identity checks',
          value: '${stats.identityAttempts}',
          icon: Icons.shield_outlined,
          qualifier: '${stats.identityAttempts - stats.identityMeasured} of '
              'these could not be performed, and are listed as unmeasured '
              'rather than dropped',
        ),
      ],
    );
  }

  static String _stamp(DateTime time) {
    final l = time.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)} '
        '${two(l.hour)}:${two(l.minute)}';
  }
}
