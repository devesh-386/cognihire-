/// Ticket 19 — HR Demo Controls.
///
/// A one-click front end for `/demo/seed` and `/demo/reset`: no terminal, no
/// Postman, everything a rehearsal or a presentation needs from this screen.
/// Deliberately thin — every decision about what gets seeded (the org, the
/// HR login, three roles, five candidates with different resume qualities)
/// and what reset preserves lives in `service/demo/`; this file only calls
/// [DemoClient] and shows what came back.
library;

import 'package:flutter/material.dart';

import '../../core/demo/demo_client.dart';
import '../../core/design/app_theme.dart';
import '../../ui/app_shell.dart';
import '../../ui/components.dart';
import '../../ui/patterns.dart';

class DemoScreen extends StatefulWidget {
  const DemoScreen({super.key, this.onCompleted});

  /// Called after a successful seed or reset — the caller uses this to
  /// refresh Candidates/Roles/AI Interviews, whose contents the demo
  /// environment just changed.
  final VoidCallback? onCompleted;

  @override
  State<DemoScreen> createState() => DemoScreenState();
}

class DemoScreenState extends State<DemoScreen> {
  final _client = DemoClient();

  DemoEnvironmentResult? _last;
  bool _seeding = false;
  bool _resetting = false;
  String? _error;

  bool get _busy => _seeding || _resetting;

  Future<void> _createEnvironment() async {
    setState(() {
      _seeding = true;
      _error = null;
    });
    try {
      final result = await _client.seed();
      if (!mounted) return;
      setState(() {
        _last = result;
        _seeding = false;
      });
      widget.onCompleted?.call();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Demo environment ready.'),
      ));
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '$error';
        _seeding = false;
      });
    }
  }

  Future<void> _resetEnvironment() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reset the demo environment?'),
        content: const Text(
          'Clears every interview session, transcript, and interview code '
          'for the demo environment, then issues fresh codes over the same '
          'candidates and roles. Candidates, their resumes, and their AI '
          'profiles are kept — you will not need to re-seed from scratch.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() {
      _resetting = true;
      _error = null;
    });
    try {
      final result = await _client.reset();
      if (!mounted) return;
      setState(() {
        _last = result;
        _resetting = false;
      });
      widget.onCompleted?.call();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Demo environment reset.'),
      ));
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '$error';
        _resetting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final last = _last;

    return ShellPage(
      title: 'Demo',
      subtitle: 'A repeatable environment for rehearsing and presenting the '
          'full workflow — one organization, an HR login, three roles, and '
          'five candidates with different resume qualities, each run '
          'through the real resume pipeline.',
      children: [
        SectionCard(
          title: 'Demo environment',
          icon: Icons.auto_fix_high_outlined,
          description: 'Create builds everything from scratch, or reuses '
              "what's already there if it was seeded before. Reset clears "
              'interview activity and re-issues fresh codes without '
              'touching candidates or profiles.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FilledButton.icon(
                onPressed: _busy ? null : _createEnvironment,
                icon: _seeding
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.play_circle_outline, size: 19),
                label: Text(
                  _seeding ? 'Creating…' : 'Create Demo Environment',
                ),
              ),
              const SizedBox(height: Spacing.sm),
              OutlinedButton.icon(
                onPressed: _busy ? null : _resetEnvironment,
                icon: _resetting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.restart_alt, size: 19),
                label: Text(_resetting ? 'Resetting…' : 'Reset Demo'),
              ),
              if (_error != null) ...[
                const SizedBox(height: Spacing.md),
                InlineNotice(tone: NoticeTone.fault, message: _error!),
              ],
            ],
          ),
        ),
        const SizedBox(height: Spacing.section),
        SectionCard(
          title: 'Status',
          icon: Icons.fact_check_outlined,
          description: last == null
              ? 'Nothing seeded yet in this session — the environment may '
                  'still exist from an earlier run; Create is idempotent, so '
                  "it's always safe to press."
              : null,
          child: last == null
              ? Text(
                  'Not seeded yet.',
                  style: theme.textTheme.bodyMedium,
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    MetricStrip(children: [
                      MetricCard(
                        label: 'Candidates',
                        value: '${last.candidateCount}',
                        icon: Icons.people_outline,
                      ),
                      MetricCard(
                        label: 'Roles',
                        value: '${last.roleCount}',
                        icon: Icons.work_outline,
                      ),
                      MetricCard(
                        label: 'Status',
                        value: 'Ready',
                        icon: Icons.check_circle_outline,
                        tone: context.evidence.verified,
                      ),
                    ]),
                    const SizedBox(height: Spacing.lg),
                    Text('Last seeded ${_stamp(last.seededAt)}',
                        style: theme.textTheme.bodySmall),
                    const SizedBox(height: Spacing.xs),
                    Text('Organization: ${last.organizationName}',
                        style: theme.textTheme.bodySmall),
                    const SizedBox(height: Spacing.xs),
                    SelectableText(
                      'HR login: ${last.hrEmail} / ${last.hrPassword}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
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
