/// Invitations: HR names a candidate against a role and gets a code to hand
/// them — the explicit link that makes a candidate's session belong to a
/// specific case rather than an anonymous walk-up.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/design/app_theme.dart';
import '../../core/invitations/invitation.dart';
import '../../core/invitations/invitation_store.dart';
import '../../core/roles/role.dart';
import '../../core/roles/role_store.dart';
import '../../ui/app_shell.dart';
import '../common/empty_state.dart';

class InvitationsScreen extends StatefulWidget {
  const InvitationsScreen({
    super.key,
    required this.invitationStore,
    required this.roleStore,
  });

  final InvitationStore invitationStore;
  final RoleStore roleStore;

  @override
  State<InvitationsScreen> createState() => InvitationsScreenState();
}

class InvitationsScreenState extends State<InvitationsScreen> {
  InvitationIndex? _index;
  RoleIndex? _roles;
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
    if (!mounted) return;
    setState(() {
      _index = index;
      _roles = roles;
      _loading = false;
    });
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
              ),
            ),
      ],
    );
  }
}

class _InvitationCard extends StatelessWidget {
  const _InvitationCard({required this.invitation, required this.role});

  final Invitation invitation;
  final Role? role;

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
            ] else
              Chip(
                avatar: const Icon(Icons.check_circle_outline, size: 16),
                label: const Text('Redeemed'),
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

  /// Six characters, unambiguous alphabet (no 0/O/1/I) — short enough to read
  /// aloud, distinct enough not to collide by typo.
  String _generateCode() {
    const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final seed = DateTime.now().microsecondsSinceEpoch;
    final buffer = StringBuffer();
    var n = seed;
    for (var i = 0; i < 6; i++) {
      buffer.write(alphabet[n % alphabet.length]);
      n ~/= alphabet.length;
      if (n == 0) n = seed ~/ (i + 7);
    }
    return buffer.toString();
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
      code: _generateCode(),
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
