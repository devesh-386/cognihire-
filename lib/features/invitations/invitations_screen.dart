/// Invitations: HR names a candidate against a role and gets a code to hand
/// them — the explicit link that makes a candidate's session belong to a
/// specific case rather than an anonymous walk-up.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/design/app_theme.dart';
import '../../core/email/email_sender.dart';
import '../../core/invitations/bulk_invite_csv.dart';
import '../../core/invitations/invitation.dart';
import '../../core/invitations/invitation_email.dart';
import '../../core/invitations/invitation_store.dart';
import '../../core/roles/role.dart';
import '../../core/roles/role_store.dart';
import '../../core/workspace/workspace_loader.dart';
import '../../core/workspace/workspace_stats.dart';
import '../../ui/app_shell.dart';
import '../audit/claim_audit_screen.dart';
import '../common/empty_state.dart';
import 'bulk_invite_csv_pick.dart';

class InvitationsScreen extends StatefulWidget {
  const InvitationsScreen({
    super.key,
    required this.invitationStore,
    required this.roleStore,
    required this.loadSessions,
    this.emailSender = const NullEmailSender(),
    this.senderName,
  });

  final InvitationStore invitationStore;
  final RoleStore roleStore;
  final EmailSender emailSender;

  /// Shown in the invitation email as "Invited by ...". Null when nobody is
  /// signed in (direct-mount call sites) — the email is simply sent without
  /// that line rather than inventing a name.
  final String? senderName;

  /// Supplied rather than an `AuditStore` directly, so this screen shares the
  /// same snapshot the rest of the app already loaded — same pattern as
  /// `RolesScreen.loadSessions`.
  final Future<WorkspaceSnapshot> Function() loadSessions;

  @override
  State<InvitationsScreen> createState() => InvitationsScreenState();
}

class InvitationsScreenState extends State<InvitationsScreen> {
  InvitationIndex? _index;
  RoleIndex? _roles;
  WorkspaceSnapshot? _snapshot;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    reload();
  }

  Future<void> reload() async {
    setState(() => _loading = true);
    final index = await widget.invitationStore.listInvitations();
    final roles = await widget.roleStore.listRoles();
    final snapshot = await widget.loadSessions();
    if (!mounted) return;
    setState(() {
      _index = index;
      _roles = roles;
      _snapshot = snapshot;
      _loading = false;
    });
  }

  /// The session this invitation's candidate produced, if their interview has
  /// been recorded. Matched by label rather than a stored session id, because
  /// nothing on the session side references the invitation — the connective
  /// tissue here is the candidate name both sides already share (see
  /// `SessionDraft.sessionTitle`, which is exactly `"name"` or
  /// `"name — role"`).
  SessionRecord? _resultFor(Invitation invitation) {
    final snapshot = _snapshot;
    if (snapshot == null) return null;
    final needle = invitation.candidateName.trim().toLowerCase();
    if (needle.isEmpty) return null;
    for (final record in snapshot.records) {
      final label = record.label.trim().toLowerCase();
      if (label == needle || label.startsWith('$needle —')) return record;
    }
    return null;
  }

  Future<void> _create() async {
    final roles = _roles?.roles ?? const <Role>[];
    if (roles.isEmpty) return;
    final created = await showDialog<Invitation>(
      context: context,
      builder: (context) => _InviteDialog(roles: roles),
    );
    if (created == null) return;
    await widget.invitationStore.saveInvitation(created);
    await reload();
  }

  Future<void> _bulkInvite() async {
    final roles = _roles?.roles ?? const <Role>[];
    if (roles.isEmpty) return;

    final picked = await pickCandidateCsv();
    if (picked == null) return; // cancelled
    if (!mounted) return;

    if (picked.text == null) {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Could not read that file'),
          content: Text(picked.error ?? 'Unknown error.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return;
    }

    final parsed = parseBulkInviteCsv(picked.text!);
    if (!mounted) return;

    final invitations = await showDialog<List<Invitation>>(
      context: context,
      builder: (context) => _BulkInviteReviewDialog(
        fileName: picked.fileName,
        parsed: parsed,
        roles: roles,
      ),
    );
    if (invitations == null || invitations.isEmpty) return;

    for (final invitation in invitations) {
      await widget.invitationStore.saveInvitation(invitation);
    }
    await reload();
    if (!mounted) return;

    // The whole point of a CSV import over the one-at-a-time dialog: at scale
    // HR cannot hand each code out by hand, so the codes go out by email
    // immediately rather than waiting for a second action per candidate.
    // Every invitation in one batch shares the role chosen in the review
    // dialog (buildInvitationsFromRows), so one lookup covers the batch.
    final role = _roleFor(invitations.first.roleId, roles);
    await _sendBatch(invitations, role);
  }

  /// Composes and sends one invitation's email, using [role]'s title (or a
  /// stated placeholder if the role has since been deleted) and the signed-in
  /// sender's name when one is known.
  Future<EmailSendResult> _sendOne(Invitation invitation, Role? role) {
    final email = composeInvitationEmail(
      invitation: invitation,
      roleTitle: role?.title ?? 'the role',
      senderName: widget.senderName,
    );
    return widget.emailSender.send(
      to: invitation.candidateEmail,
      subject: email.subject,
      body: email.body,
    );
  }

  Future<void> _sendSingle(Invitation invitation, Role? role) async {
    final result = await _sendOne(invitation, role);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      duration: Duration(seconds: result.success ? 4 : 10),
      content: Text(
        result.success
            ? 'Emailed the code to ${invitation.candidateEmail}.'
            : 'Could not email ${invitation.candidateEmail}: ${result.error}',
      ),
    ));
  }

  /// Sends every invitation in [invitations] that has an email, and reports a
  /// count — never a silent "done" that hides which ones actually failed to
  /// go out.
  Future<void> _sendBatch(List<Invitation> invitations, Role? role) async {
    final withEmail = invitations.where((i) => i.candidateEmail.isNotEmpty).toList();
    if (withEmail.isEmpty) return;

    var sent = 0;
    final failures = <String>[];
    for (final invitation in withEmail) {
      final result = await _sendOne(invitation, role);
      if (result.success) {
        sent++;
      } else {
        failures.add('${invitation.candidateName}: ${result.error}');
      }
    }
    if (!mounted) return;

    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Bulk invite emails'),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('$sent of ${withEmail.length} sent successfully.'),
              if (failures.isNotEmpty) ...[
                const SizedBox(height: Spacing.sm),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 160),
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final failure in failures)
                          Padding(
                            padding: const EdgeInsets.only(top: Spacing.xs),
                            child: Text(
                              failure,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(
                                    color: Theme.of(context).colorScheme.error,
                                  ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: Spacing.sm),
                const Text(
                  'The codes above are still valid — copy and send them '
                  'from the list, or retry.',
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Role? _roleFor(String id, List<Role> roles) {
    for (final role in roles) {
      if (role.id == id) return role;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final index = _index;
    final roles = _roles?.roles ?? const <Role>[];

    return ShellPage(
      title: 'Invitations',
      subtitle: 'Invite a candidate to interview for a role. They redeem the '
          'code you give them, and their session is bound to that role from '
          'the start.',
      actions: [
        IconButton(
          onPressed: _loading ? null : reload,
          tooltip: 'Refresh',
          icon: const Icon(Icons.refresh, size: 20),
        ),
        OutlinedButton.icon(
          onPressed: roles.isEmpty ? null : _bulkInvite,
          icon: const Icon(Icons.upload_file_outlined, size: 18),
          label: const Text('Bulk invite (CSV)'),
        ),
        FilledButton.icon(
          onPressed: roles.isEmpty ? null : _create,
          icon: const Icon(Icons.person_add_alt_1, size: 18),
          label: const Text('Invite candidate'),
        ),
      ],
      children: [
        if (_loading && index == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: Spacing.hero),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (roles.isEmpty)
          const EmptyState(
            icon: Icons.work_outline,
            title: 'Define a role first',
            body: 'An invitation is issued against a role, so there is '
                'something to point the candidate\'s interview at. Add one on '
                'the Roles screen, then come back here.',
          )
        else if (index == null || index.invitations.isEmpty)
          EmptyState(
            icon: Icons.person_add_alt_1_outlined,
            title: 'No invitations yet',
            body: 'Invite a candidate and they will appear here with the '
                'code to give them.',
            actionLabel: 'Invite candidate',
            onAction: _create,
          )
        else
          for (final invitation in index.invitations)
            Padding(
              padding: const EdgeInsets.only(bottom: Spacing.lg),
              child: _InvitationCard(
                invitation: invitation,
                role: _roleFor(invitation.roleId, roles),
                result: _resultFor(invitation),
                onSendEmail: invitation.candidateEmail.isEmpty
                    ? null
                    : () => _sendSingle(
                          invitation,
                          _roleFor(invitation.roleId, roles),
                        ),
              ),
            ),
      ],
    );
  }
}

class _InvitationCard extends StatelessWidget {
  const _InvitationCard({
    required this.invitation,
    required this.role,
    required this.result,
    required this.onSendEmail,
  });

  final Invitation invitation;
  final Role? role;

  /// This candidate's finished session, once one exists. Null before they
  /// have completed an interview — see `InvitationsScreenState._resultFor`.
  final SessionRecord? result;

  /// Null when this invitation has no candidate email to send to — the
  /// button is hidden rather than shown disabled with no way to explain why.
  final VoidCallback? onSendEmail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accepted = invitation.status == InvitationStatus.accepted;
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.surface),
      ),
      child: Padding(
        padding: const EdgeInsets.all(Spacing.lg),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(invitation.candidateName,
                      style: theme.textTheme.titleMedium),
                  const SizedBox(height: Spacing.xs),
                  Text(
                    // A role that no longer exists is stated, not hidden — an
                    // invitation pointing nowhere is a fact HR should see.
                    role?.title ?? 'Role no longer exists',
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            if (!accepted) ...[
              SelectableText(
                invitation.code,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                  letterSpacing: 2,
                ),
              ),
              const SizedBox(width: Spacing.sm),
              IconButton(
                tooltip: 'Copy code',
                icon: const Icon(Icons.copy_outlined, size: 18),
                onPressed: () =>
                    Clipboard.setData(ClipboardData(text: invitation.code)),
              ),
              if (onSendEmail != null) ...[
                const SizedBox(width: Spacing.xs),
                IconButton(
                  tooltip: 'Email the code to ${invitation.candidateEmail}',
                  icon: const Icon(Icons.email_outlined, size: 18),
                  onPressed: onSendEmail,
                ),
              ],
            ] else if (result != null)
              OutlinedButton.icon(
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => ClaimAuditScreen(
                    audit: result!.audit,
                    label: result!.label,
                  ),
                )),
                icon: const Icon(Icons.fact_check_outlined, size: 18),
                label: const Text('View report'),
              )
            else
              Chip(
                avatar: const Icon(Icons.hourglass_empty, size: 16),
                label: const Text('Redeemed — awaiting interview'),
              ),
          ],
        ),
      ),
    );
  }
}

class _InviteDialog extends StatefulWidget {
  const _InviteDialog({required this.roles});

  final List<Role> roles;

  @override
  State<_InviteDialog> createState() => _InviteDialogState();
}

class _InviteDialogState extends State<_InviteDialog> {
  final _name = TextEditingController();
  final _email = TextEditingController();
  String? _roleId;
  String? _error;

  @override
  void initState() {
    super.initState();
    _roleId = widget.roles.first.id;
  }

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Enter the candidate\'s name.');
      return;
    }
    final roleId = _roleId;
    if (roleId == null) {
      setState(() => _error = 'Pick a role.');
      return;
    }
    Navigator.of(context).pop(Invitation(
      id: 'inv-${DateTime.now().microsecondsSinceEpoch}',
      candidateName: name,
      candidateEmail: _email.text.trim(),
      roleId: roleId,
      code: generateInvitationCode(),
      createdAt: DateTime.now(),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Invite candidate'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Candidate name'),
              autofocus: true,
            ),
            const SizedBox(height: Spacing.md),
            TextField(
              controller: _email,
              decoration: const InputDecoration(
                labelText: 'Email (optional)',
              ),
            ),
            const SizedBox(height: Spacing.md),
            DropdownButtonFormField<String>(
              initialValue: _roleId,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Role'),
              items: [
                for (final role in widget.roles)
                  DropdownMenuItem(value: role.id, child: Text(role.title)),
              ],
              onChanged: (value) => setState(() => _roleId = value),
            ),
            if (_error != null) ...[
              const SizedBox(height: Spacing.md),
              Text(_error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Create invitation')),
      ],
    );
  }
}

/// Shows what came out of parsing HR's CSV — every valid row, every row that
/// needs fixing and why — before anything is actually created. Returns the
/// built [Invitation]s on confirm, or null if HR cancelled.
class _BulkInviteReviewDialog extends StatefulWidget {
  const _BulkInviteReviewDialog({
    required this.fileName,
    required this.parsed,
    required this.roles,
  });

  final String fileName;
  final BulkInviteParseResult parsed;
  final List<Role> roles;

  @override
  State<_BulkInviteReviewDialog> createState() =>
      _BulkInviteReviewDialogState();
}

class _BulkInviteReviewDialogState extends State<_BulkInviteReviewDialog> {
  late String _roleId = widget.roles.first.id;

  void _confirm() {
    final invitations = buildInvitationsFromRows(widget.parsed.rows, _roleId);
    Navigator.of(context).pop(invitations);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = widget.parsed.rows;
    final errors = widget.parsed.errors;

    return AlertDialog(
      title: Text('Bulk invite — ${widget.fileName}'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (rows.isEmpty && errors.isEmpty)
              const Text('The file has no rows to import.')
            else ...[
              Text(
                errors.isEmpty
                    ? '${rows.length} candidate(s) ready to invite.'
                    : '${rows.length} ready, ${errors.length} need fixing:',
                style: theme.textTheme.bodyMedium,
              ),
              if (errors.isNotEmpty) ...[
                const SizedBox(height: Spacing.sm),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 160),
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final error in errors)
                          Padding(
                            padding: const EdgeInsets.only(bottom: Spacing.xs),
                            child: Text(
                              'Line ${error.lineNumber}: ${error.reason}',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.error,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
              if (rows.isNotEmpty) ...[
                const SizedBox(height: Spacing.md),
                DropdownButtonFormField<String>(
                  initialValue: _roleId,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Role for all'),
                  items: [
                    for (final role in widget.roles)
                      DropdownMenuItem(value: role.id, child: Text(role.title)),
                  ],
                  onChanged: (value) =>
                      setState(() => _roleId = value ?? _roleId),
                ),
              ],
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        if (rows.isNotEmpty)
          FilledButton(
            onPressed: _confirm,
            child: Text('Invite ${rows.length}'),
          ),
      ],
    );
  }
}
