import 'package:flutter/material.dart';

import '../../core/claims/claim_audit.dart';
import '../../core/design/app_theme.dart';
import '../../core/persistence/audit_store.dart';
import '../audit/claim_audit_screen.dart';
import '../common/empty_state.dart';

/// Sessions saved on this machine.
///
/// Shows unreadable records alongside readable ones. A stored audit that fails
/// to load is a fact the reviewer needs — quietly filtering it out would leave
/// them believing they had seen every session, which is the same error as
/// reporting an unmeasured check as a pass, reached by omission instead.
class SessionHistoryScreen extends StatefulWidget {
  const SessionHistoryScreen({
    super.key,
    required this.store,
    required this.storageLocation,
    required this.storageIsDurable,
  });

  final AuditStore store;
  final String storageLocation;
  final bool storageIsDurable;

  @override
  State<SessionHistoryScreen> createState() => _SessionHistoryScreenState();
}

class _SessionHistoryScreenState extends State<SessionHistoryScreen> {
  late Future<SessionIndex> _index;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _refresh() {
    // Block body, not an arrow. `() => _index = future` returns the assigned
    // value — a Future — and setState rejects a callback that returns one.
    // The work is kicked off here and awaited by the FutureBuilder; setState
    // only swaps which Future is being watched.
    setState(() {
      _index = widget.store.listSessions();
    });
  }

  Future<void> _open(SessionSummary summary) async {
    final ClaimAudit audit;
    try {
      audit = await widget.store.loadAudit(summary.id);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open ${summary.label}: $error')),
      );
      return;
    }

    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ClaimAuditScreen(audit: audit, label: summary.label),
      ),
    );
  }

  Future<void> _delete(String id) async {
    await widget.store.deleteAudit(id);
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Past sessions'),
        actions: [
          IconButton(
            onPressed: _refresh,
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: FutureBuilder<SessionIndex>(
        future: _index,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }

          if (snapshot.hasError) {
            return EmptyState(
              icon: Icons.error_outline,
              tone: EmptyStateTone.fault,
              title: 'Could not read stored sessions',
              body: '${snapshot.error}',
              actionLabel: 'Try again',
              onAction: _refresh,
            );
          }

          final index = snapshot.data!;

          if (index.total == 0) {
            return EmptyState(
              icon: Icons.inbox_outlined,
              title: 'No saved sessions yet',
              body: widget.storageIsDurable
                  ? 'Finish an interview and its audit is saved here '
                      'automatically, to ${widget.storageLocation}'
                  : widget.storageLocation,
            );
          }

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _storageNotice(theme),
              const SizedBox(height: 12),
              for (final session in index.sessions) _sessionTile(session),
              if (index.hasUnreadable) ...[
                const SizedBox(height: 20),
                Text(
                  'Unreadable records',
                  style: theme.textTheme.titleSmall
                      ?.copyWith(color: theme.colorScheme.error),
                ),
                const SizedBox(height: 4),
                Text(
                  'These files exist but could not be decoded. They are listed '
                  'rather than hidden so the count of sessions stays honest.',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                for (final broken in index.unreadable) _unreadableTile(broken),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _storageNotice(ThemeData theme) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: widget.storageIsDurable
              ? theme.colorScheme.surfaceContainerHighest
              : theme.colorScheme.errorContainer,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              widget.storageIsDurable ? Icons.save_outlined : Icons.warning_amber,
              size: 18,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                widget.storageIsDurable
                    ? 'Saved to ${widget.storageLocation}'
                    : widget.storageLocation,
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        ),
      );

  Widget _sessionTile(SessionSummary session) {
    final theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        onTap: () => _open(session),
        leading: _provenanceBadge(session.provenanceQuality),
        title: Text(session.label),
        subtitle: Text(
          '${_formatDate(session.sessionEnd)} · '
          '${session.claimCount} claims · '
          '${session.duration.inMinutes} min · '
          '${_provenanceLabel(session.provenanceQuality)}',
          style: theme.textTheme.bodySmall,
        ),
        trailing: IconButton(
          icon: const Icon(Icons.delete_outline),
          tooltip: 'Delete',
          onPressed: () => _confirmDelete(session),
        ),
      ),
    );
  }

  Future<void> _confirmDelete(SessionSummary session) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete this session?'),
        content: Text(
          'The audit for "${session.label}" will be removed from this machine. '
          'This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed ?? false) await _delete(session.id);
  }

  Widget _unreadableTile(UnreadableSession broken) => Card(
        margin: const EdgeInsets.only(bottom: 10),
        color: Theme.of(context).colorScheme.errorContainer,
        child: ListTile(
          leading: const Icon(Icons.broken_image_outlined),
          title: Text(broken.id),
          subtitle: Text(
            broken.problem,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          trailing: IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Delete',
            onPressed: () => _delete(broken.id),
          ),
        ),
      );

  Widget _provenanceBadge(ProvenanceQuality quality) {
    final (colour, icon) = switch (quality) {
      ProvenanceQuality.solid =>
        (context.evidence.verified, Icons.verified_outlined),
      ProvenanceQuality.disputed =>
        (context.evidence.disputed, Icons.error_outline),
      ProvenanceQuality.sparse => (context.evidence.unmeasured, Icons.blur_on),
      ProvenanceQuality.none =>
        (context.evidence.notExamined, Icons.help_outline),
    };

    return CircleAvatar(
      backgroundColor: colour.withValues(alpha: 0.12),
      child: Icon(icon, color: colour, size: 20),
    );
  }

  static String _provenanceLabel(ProvenanceQuality quality) =>
      switch (quality) {
        ProvenanceQuality.solid => 'identity verified throughout',
        ProvenanceQuality.disputed => 'identity disputed',
        ProvenanceQuality.sparse => 'identity coverage incomplete',
        ProvenanceQuality.none => 'identity not verified',
      };

  static String _formatDate(DateTime time) {
    final local = time.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }

}
