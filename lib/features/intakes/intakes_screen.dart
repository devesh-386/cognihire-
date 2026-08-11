/// A role's hiring campaigns. Pushed from a role card in [RolesScreen] —
/// see Part 29 of the multi-tenant intake work: Organization -> Role ->
/// Intake -> Candidates is the navigation the recruiter actually walks.
library;

import 'package:flutter/material.dart';

import '../../core/design/app_theme.dart';
import '../../core/intakes/intake.dart';
import '../../core/intakes/intake_store.dart';
import '../../core/roles/role.dart';
import '../../ui/app_shell.dart';
import '../../ui/components.dart';
import '../../ui/patterns.dart';
import '../common/empty_state.dart';

class IntakesScreen extends StatefulWidget {
  const IntakesScreen({super.key, required this.role, required this.intakeStore});

  final Role role;
  final IntakeStore intakeStore;

  @override
  State<IntakesScreen> createState() => _IntakesScreenState();
}

class _IntakesScreenState extends State<IntakesScreen> {
  List<Intake>? _intakes;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    try {
      final intakes = await widget.intakeStore.listForRole(widget.role.id);
      if (!mounted) return;
      setState(() {
        _intakes = intakes;
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _createIntake() async {
    final name = await showDialog<String>(
      context: context,
      builder: (context) => const _NewIntakeDialog(),
    );
    if (name == null || name.trim().isEmpty) return;
    try {
      await widget.intakeStore.create(roleId: widget.role.id, name: name.trim());
      await _reload();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not create intake: $error')));
    }
  }

  Future<void> _setStatus(Intake intake, IntakeStatus status) async {
    try {
      await widget.intakeStore.updateStatus(intake.id, status);
      await _reload();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not update status: $error')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final intakes = _intakes;

    return ShellPage(
      title: '${widget.role.title} — Intakes',
      subtitle: 'Each intake is one campaign. Two intakes for this role never '
          'share candidates — a candidate belongs to exactly one.',
      actions: [
        IconButton(
          onPressed: _loading ? null : _reload,
          tooltip: 'Refresh',
          icon: const Icon(Icons.refresh, size: 20),
        ),
        FilledButton.icon(
          onPressed: _createIntake,
          icon: const Icon(Icons.add, size: 18),
          label: const Text('New intake'),
        ),
      ],
      children: [
        if (_loading && intakes == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: Spacing.hero),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_error != null)
          InlineNotice(tone: NoticeTone.fault, message: 'Intakes could not be read: $_error')
        else if (intakes == null || intakes.isEmpty)
          EmptyState(
            icon: Icons.campaign_outlined,
            title: 'No intakes yet',
            body: 'Start a campaign for ${widget.role.title} — e.g. '
                '"August 2026 Intake" — and every candidate who applies through '
                'it stays scoped to this one campaign.',
            actionLabel: 'New intake',
            onAction: _createIntake,
          )
        else
          for (final intake in intakes)
            Padding(
              padding: const EdgeInsets.only(bottom: Spacing.lg),
              child: _IntakeCard(intake: intake, onStatus: (s) => _setStatus(intake, s)),
            ),
      ],
    );
  }
}

class _IntakeCard extends StatelessWidget {
  const _IntakeCard({required this.intake, required this.onStatus});

  final Intake intake;
  final void Function(IntakeStatus) onStatus;

  Color _tone(BuildContext context, IntakeStatus status) {
    final scheme = Theme.of(context).colorScheme;
    return switch (status) {
      IntakeStatus.draft => scheme.outline,
      IntakeStatus.active => scheme.secondary,
      IntakeStatus.paused => scheme.tertiary,
      IntakeStatus.closed => scheme.error,
    };
  }

  List<(String, IntakeStatus)> _availableActions() => switch (intake.status) {
        IntakeStatus.draft => const [('Activate', IntakeStatus.active), ('Close', IntakeStatus.closed)],
        IntakeStatus.active => const [('Pause', IntakeStatus.paused), ('Close', IntakeStatus.closed)],
        IntakeStatus.paused => const [('Resume', IntakeStatus.active), ('Close', IntakeStatus.closed)],
        IntakeStatus.closed => const [],
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Spacing.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(intake.name, style: theme.textTheme.titleLarge),
                      const SizedBox(height: 2),
                      Text(_date(intake.createdAt), style: theme.textTheme.bodySmall),
                    ],
                  ),
                ),
                Tag(label: intake.status.wireValue, tone: _tone(context, intake.status)),
              ],
            ),
            const SizedBox(height: Spacing.lg),
            Text(
              intake.applicationUrl == null
                  ? 'No application form connected yet.'
                  : 'Application URL: ${intake.applicationUrl}',
              style: theme.textTheme.bodySmall,
            ),
            if (_availableActions().isNotEmpty) ...[
              const SizedBox(height: Spacing.lg),
              Wrap(
                spacing: Spacing.sm,
                children: [
                  for (final (label, status) in _availableActions())
                    OutlinedButton(
                      onPressed: () => onStatus(status),
                      child: Text(label),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _date(DateTime time) {
    final l = time.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)}';
  }
}

class _NewIntakeDialog extends StatefulWidget {
  const _NewIntakeDialog();

  @override
  State<_NewIntakeDialog> createState() => _NewIntakeDialogState();
}

class _NewIntakeDialogState extends State<_NewIntakeDialog> {
  final _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New intake'),
      content: TextField(
        controller: _name,
        autofocus: true,
        decoration: const InputDecoration(
          labelText: 'Intake name',
          hintText: 'e.g. August 2026 Intake',
        ),
        onSubmitted: (_) => Navigator.of(context).pop(_name.text),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_name.text),
          child: const Text('Create'),
        ),
      ],
    );
  }
}
