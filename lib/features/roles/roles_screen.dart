/// Roles: locally-authored skill requirements, and how sessions cover them.
///
/// ## What replaced the mockup's score
///
/// The design had an **"ATS Alignment: 88 — EXCELLENT"** ring and a
/// **candidate leaderboard** ranked by unexplained points. Both are gone, and
/// what is here instead answers the same question without inventing anything: for
/// each skill the role asks for, did the candidate claim it, and was that claim
/// examined?
///
/// The ring is still on screen, because a ring is a good way to read a
/// proportion. It now shows a proportion that exists — required skills with a
/// substantiated claim, out of required skills — with both counts printed beside
/// it. When a role lists no required skills the ring shows a dash rather than a
/// full circle, because there is no ratio to draw.
///
/// The leaderboard is not replaced by a quieter leaderboard. There is no ordering
/// of people here at all: ranking candidates is the automated employment decision
/// this tool exists not to make.
library;

import 'package:flutter/material.dart';

import '../../core/design/app_theme.dart';
import '../../core/roles/role.dart';
import '../../core/roles/role_coverage.dart';
import '../../core/roles/role_store.dart';
import '../../core/workspace/workspace_loader.dart';
import '../../core/workspace/workspace_stats.dart';
import '../../ui/app_shell.dart';
import '../../ui/components.dart';
import '../../ui/patterns.dart';
import '../common/empty_state.dart';

class RolesScreen extends StatefulWidget {
  const RolesScreen({
    super.key,
    required this.roleStore,
    required this.loadSessions,
  });

  final RoleStore roleStore;

  /// Supplied rather than the store itself so this screen shares whatever
  /// snapshot the rest of the app already loaded instead of re-reading every
  /// audit from disk.
  final Future<WorkspaceSnapshot> Function() loadSessions;

  @override
  State<RolesScreen> createState() => RolesScreenState();
}

class RolesScreenState extends State<RolesScreen> {
  RoleIndex? _index;
  WorkspaceSnapshot? _snapshot;
  bool _loading = true;

  /// Which session the coverage table is computed against. Null until the user
  /// picks one; the table refuses to guess, because comparing a role to an
  /// arbitrary session and labelling it "coverage" would be meaningless.
  String? _againstSessionId;

  @override
  void initState() {
    super.initState();
    reload();
  }

  Future<void> reload() async {
    setState(() => _loading = true);
    final index = await widget.roleStore.listRoles();
    final snapshot = await widget.loadSessions();
    if (!mounted) return;
    setState(() {
      _index = index;
      _snapshot = snapshot;
      _loading = false;
      // Default to the most recent session once one exists, which is almost
      // always the one the author wants to check a freshly-written role against.
      _againstSessionId ??= snapshot.records.isEmpty
          ? null
          : snapshot.records.first.id;
    });
  }

  Future<void> _edit({Role? existing}) async {
    final saved = await showDialog<Role>(
      context: context,
      builder: (context) => _RoleDialog(existing: existing),
    );
    if (saved == null) return;

    await widget.roleStore.saveRole(saved);
    await reload();
  }

  Future<void> _delete(Role role) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete "${role.title}"?'),
        content: const Text(
          'The role definition is removed. Sessions already recorded are not '
          'affected — a role is only a lens to read them through.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep it'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(
              'Delete',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await widget.roleStore.deleteRole(role.id);
    await reload();
  }

  @override
  Widget build(BuildContext context) {
    final index = _index;

    return ShellPage(
      title: 'Roles',
      subtitle: 'A role is a list of skills you decided the position needs. '
          'Matching it against a session reports coverage — it does not score '
          'or rank anybody.',
      actions: [
        IconButton(
          onPressed: _loading ? null : reload,
          tooltip: 'Refresh',
          icon: const Icon(Icons.refresh, size: 20),
        ),
        FilledButton.icon(
          onPressed: () => _edit(),
          icon: const Icon(Icons.add, size: 18),
          label: const Text('New role'),
        ),
      ],
      children: [
        if (_loading && index == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: Spacing.hero),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (index == null)
          const InlineNotice(
            tone: NoticeTone.fault,
            message: 'Roles could not be read.',
          )
        else ...[
          if (index.problem != null) ...[
            InlineNotice(
              tone: NoticeTone.fault,
              icon: Icons.error_outline,
              message: index.problem!,
            ),
            const SizedBox(height: Spacing.xl),
          ],
          if (index.roles.isEmpty)
            EmptyState(
              icon: Icons.work_outline,
              title: 'No roles defined',
              body: 'Define a role and every session can be read against it: '
                  'which required skills were claimed, which were examined, and '
                  'which were never mentioned.',
              actionLabel: 'Define a role',
              onAction: () => _edit(),
            )
          else ...[
            _sessionPicker(context),
            const SizedBox(height: Spacing.xl),
            for (final role in index.roles)
              Padding(
                padding: const EdgeInsets.only(bottom: Spacing.xl),
                child: _RoleCard(
                  role: role,
                  against: _againstSessionId == null
                      ? null
                      : _snapshot?.recordFor(_againstSessionId!),
                  onEdit: () => _edit(existing: role),
                  onDelete: () => _delete(role),
                ),
              ),
          ],
        ],
      ],
    );
  }

  Widget _sessionPicker(BuildContext context) {
    final theme = Theme.of(context);
    final records = _snapshot?.records ?? const [];

    if (records.isEmpty) {
      return InlineNotice(
        tone: NoticeTone.caution,
        message: 'No sessions are stored, so coverage cannot be computed yet. '
            'The roles below are saved and will be matched as soon as a session '
            'exists.',
        action: TextButton(
          onPressed: () => AppShellController.of(context)?.goTo('New session'),
          child: const Text('Run one'),
        ),
      );
    }

    return SectionCard(
      title: 'Read roles against',
      icon: Icons.compare_arrows_outlined,
      description: 'Coverage is always relative to one session. Pick which.',
      child: DropdownButtonFormField<String>(
        initialValue: _againstSessionId,
        isExpanded: true,
        decoration: const InputDecoration(labelText: 'Session'),
        items: [
          for (final record in records)
            DropdownMenuItem(
              value: record.id,
              child: Text(
                '${record.label} — ${record.audit.findings.length} claim(s), '
                '${_date(record.audit.sessionEnd)}',
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium,
              ),
            ),
        ],
        onChanged: (value) => setState(() => _againstSessionId = value),
      ),
    );
  }

  static String _date(DateTime time) {
    final l = time.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)}';
  }
}

class _RoleCard extends StatelessWidget {
  const _RoleCard({
    required this.role,
    required this.against,
    required this.onEdit,
    required this.onDelete,
  });

  final Role role;
  final SessionRecord? against;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final record = against;
    final coverage = record == null ? null : coverageFor(role, record.audit);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Spacing.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(role.title, style: theme.textTheme.titleLarge),
                      const SizedBox(height: 2),
                      Text(
                        '${role.requiredSkills.length} required · '
                        '${role.desirableSkills.length} desirable · defined '
                        '${_date(role.createdAt)}',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: onEdit,
                  tooltip: 'Edit this role',
                  icon: const Icon(Icons.edit_outlined, size: 18),
                ),
                IconButton(
                  onPressed: onDelete,
                  tooltip: 'Delete this role',
                  icon: const Icon(Icons.delete_outline, size: 18),
                ),
              ],
            ),
            if (role.notes.trim().isNotEmpty) ...[
              const SizedBox(height: Spacing.md),
              Text(role.notes.trim(), style: theme.textTheme.bodyMedium),
            ],
            const SizedBox(height: Spacing.xl),
            if (coverage == null)
              Text(
                'Pick a session above to read this role against it.',
                style: theme.textTheme.bodySmall,
              )
            else
              _coverage(context, coverage, record!),
          ],
        ),
      ),
    );
  }

  Widget _coverage(
    BuildContext context,
    RoleCoverage coverage,
    SessionRecord record,
  ) {
    final theme = Theme.of(context);

    final table = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(coverage.summary, style: theme.textTheme.bodyMedium),
        const SizedBox(height: Spacing.lg),
        for (final row in coverage.rows) _row(context, row),
        if (coverage.untaggedClaims > 0) ...[
          const SizedBox(height: Spacing.md),
          Text(
            '${coverage.untaggedClaims} claim(s) in this session carry no skill '
            'tag, so this table cannot speak to them.',
            style: theme.textTheme.bodySmall,
          ),
        ],
        if (coverage.claimsOutsideRole.isNotEmpty) ...[
          const SizedBox(height: Spacing.md),
          Text(
            'Also claimed, but not asked for by this role: '
            '${coverage.claimsOutsideRole.join(', ')}.',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ],
    );

    final gauge = Column(
      children: [
        RingGauge(
          diameter: 124,
          fraction: coverage.requiredSubstantiatedFraction,
          caption: 'covered',
          centreLabel: coverage.requiredRows.isEmpty
              ? null
              : '${coverage.requiredSubstantiated}'
                  '/${coverage.requiredRows.length}',
          unavailableNote: 'no required\nskills',
        ),
        const SizedBox(height: Spacing.md),
        Text(
          'Required skills with a substantiated claim in ${record.label}\'s '
          'session.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall,
        ),
      ],
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 620) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [gauge, const SizedBox(height: Spacing.xl), table],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: table),
            const SizedBox(width: Spacing.xxl),
            SizedBox(width: 200, child: gauge),
          ],
        );
      },
    );
  }

  Widget _row(BuildContext context, SkillCoverageRow row) {
    final theme = Theme.of(context);
    final evidence = context.evidence;

    final (String label, Color colour, IconData icon) = switch (row.state) {
      SkillEvidenceState.substantiatedClaim => (
          'Claimed and substantiated',
          evidence.verified,
          Icons.check_circle_outline,
        ),
      SkillEvidenceState.examinedClaim => (
          'Claimed, examined, no ruling yet',
          evidence.unmeasured,
          Icons.pending_outlined,
        ),
      SkillEvidenceState.claimedNotExamined => (
          'Claimed but never tested',
          evidence.notExamined,
          Icons.radio_button_unchecked,
        ),
      SkillEvidenceState.noClaim => (
          'Not claimed in this session',
          evidence.disputed,
          Icons.remove_circle_outline,
        ),
    };

    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: colour),
          const SizedBox(width: Spacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        row.skill,
                        style: theme.textTheme.titleSmall,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: Spacing.sm),
                    if (row.required_)
                      Tag(label: 'required', tone: theme.colorScheme.secondary)
                    else
                      const Tag(label: 'desirable'),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  row.claimCount == 0
                      ? label
                      : '$label · ${row.claimCount} claim(s)',
                  style: theme.textTheme.bodySmall?.copyWith(color: colour),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _date(DateTime time) {
    final l = time.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)}';
  }
}

/// Create-or-edit dialog for a role.
class _RoleDialog extends StatefulWidget {
  const _RoleDialog({this.existing});

  final Role? existing;

  @override
  State<_RoleDialog> createState() => _RoleDialogState();
}

class _RoleDialogState extends State<_RoleDialog> {
  late final _title = TextEditingController(text: widget.existing?.title ?? '');
  late final _required = TextEditingController(
    text: widget.existing?.requiredSkills.join(', ') ?? '',
  );
  late final _desirable = TextEditingController(
    text: widget.existing?.desirableSkills.join(', ') ?? '',
  );
  late final _notes = TextEditingController(text: widget.existing?.notes ?? '');

  String? _error;

  @override
  void dispose() {
    _title.dispose();
    _required.dispose();
    _desirable.dispose();
    _notes.dispose();
    super.dispose();
  }

  static List<String> _parseSkills(String raw) => raw
      .split(RegExp(r'[,\n]'))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();

  void _save() {
    final title = _title.text.trim();
    if (title.isEmpty) {
      setState(() => _error = 'A role needs a title.');
      return;
    }

    final required = _parseSkills(_required.text);
    if (required.isEmpty) {
      setState(() => _error =
          'List at least one required skill. A role with no requirements would '
          'report complete coverage of nothing.');
      return;
    }

    final existing = widget.existing;
    Navigator.of(context).pop(
      existing == null
          ? Role(
              // Millisecond timestamp: unique enough for a locally-authored list
              // and sorts by creation without a second field.
              id: 'role-${DateTime.now().millisecondsSinceEpoch}',
              title: title,
              requiredSkills: required,
              desirableSkills: _parseSkills(_desirable.text),
              notes: _notes.text.trim(),
              createdAt: DateTime.now(),
            )
          : existing.copyWith(
              title: title,
              requiredSkills: required,
              desirableSkills: _parseSkills(_desirable.text),
              notes: _notes.text.trim(),
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: Text(widget.existing == null ? 'Define a role' : 'Edit role'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _title,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Role title',
                  hintText: 'e.g. Senior backend engineer',
                ),
              ),
              const SizedBox(height: Spacing.lg),
              TextField(
                controller: _required,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Required skills',
                  hintText: 'PostgreSQL, React, CI/CD',
                  helperText: 'Comma separated. Matched against claim skill '
                      'tags, case-insensitively and with no fuzzy matching — a '
                      'near-miss is reported as a gap so you can fix the '
                      'spelling.',
                  helperMaxLines: 4,
                ),
              ),
              const SizedBox(height: Spacing.lg),
              TextField(
                controller: _desirable,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Desirable skills (optional)',
                  hintText: 'Kubernetes, Rust',
                ),
              ),
              const SizedBox(height: Spacing.lg),
              TextField(
                controller: _notes,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Notes (optional)',
                  hintText: 'Context for whoever reads a coverage report later.',
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: Spacing.lg),
                Text(
                  _error!,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Save role')),
      ],
    );
  }
}
