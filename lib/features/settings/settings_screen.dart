/// Settings: the things about this installation a user can actually change,
/// plus the things they cannot but should know.
///
/// Every control here mutates real state. Where a setting would be meaningless
/// in a local-first app with no accounts — team members, notification
/// preferences, billing, all of which the mockup implied — it is absent rather
/// than present and inert.
library;

import 'package:flutter/material.dart';

import '../../core/claims/claim_extractor.dart';
import '../../core/claims/claim_extractor_factory.dart';
import '../../core/design/app_theme.dart';
import '../../core/persistence/audit_store.dart';
import '../../core/persistence/json_codec.dart';
import '../../core/workspace/workspace_loader.dart';
import '../../ui/app_shell.dart';
import '../../ui/components.dart';
import '../../ui/patterns.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.store,
    required this.storageLocation,
    required this.storageIsDurable,
    required this.themeMode,
    required this.onThemeModeChanged,
    this.onDataChanged,
    this.extractor,
  });

  final AuditStore store;
  final String storageLocation;
  final bool storageIsDurable;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeModeChanged;

  /// Called after sessions or the enrolment are deleted, so the rest of the app
  /// stops showing records that no longer exist.
  final VoidCallback? onDataChanged;

  final ClaimExtractor? extractor;

  @override
  State<SettingsScreen> createState() => SettingsScreenState();
}

class SettingsScreenState extends State<SettingsScreen> {
  EnrolmentProfile? _enrolment;
  String? _enrolmentError;
  bool _loading = true;

  int _sessionCount = 0;

  /// Result of the last extractor reachability check. Null means "not checked
  /// yet" — distinct from "checked and unreachable", which is the whole point.
  ({bool reachable, String detail})? _extractorState;
  bool _checkingExtractor = false;

  @override
  void initState() {
    super.initState();
    reload();
  }

  Future<void> reload() async {
    setState(() => _loading = true);

    EnrolmentProfile? profile;
    String? error;
    try {
      profile = await widget.store.loadEnrolment();
    } catch (e) {
      error = '$e';
    }

    final snapshot = await loadWorkspace(widget.store);

    if (!mounted) return;
    setState(() {
      _enrolment = profile;
      _enrolmentError = error;
      _sessionCount = snapshot.records.length;
      _loading = false;
    });
  }

  Future<void> _checkExtractor() async {
    setState(() => _checkingExtractor = true);
    final extractor = widget.extractor ?? createDefaultClaimExtractor();

    // The honest reachability test is to actually run the thing on a line we
    // know is groundable, and see whether the local model or the fallback text
    // rules answered. Pinging a port would prove less.
    const probe = 'Built and shipped a React dashboard used by 200+ staff.';
    try {
      final result = await extractor.extract(probe, source: 'Settings check');
      if (!mounted) return;
      setState(() {
        _extractorState = result.degradedReason == null
            ? (
                reachable: true,
                detail: '${result.kind.label} answered and produced '
                    '${result.claims.length} claim(s) from the probe line.',
              )
            : (
                reachable: false,
                detail: 'Fell back to text rules: ${result.degradedReason}',
              );
        _checkingExtractor = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _extractorState = (reachable: false, detail: '$error');
        _checkingExtractor = false;
      });
    }
  }

  Future<void> _clearEnrolment() async {
    final confirmed = await _confirm(
      title: 'Discard the enrolled reference face?',
      body: 'The stored embedding is deleted. The next session will capture a '
          'new reference before it starts — there is no unverified path, so '
          'nothing becomes less verified by doing this.',
      action: 'Discard it',
    );
    if (!confirmed) return;

    await widget.store.clearEnrolment();
    widget.onDataChanged?.call();
    await reload();
  }

  Future<void> _deleteAllSessions() async {
    final confirmed = await _confirm(
      title: 'Delete all $_sessionCount stored session(s)?',
      body: 'Every audit, its evidence trail, and its hash-chained event log '
          'are removed permanently. There is no undo and no copy elsewhere. If '
          'you need these, export them from Reports first.',
      action: 'Delete everything',
      destructive: true,
    );
    if (!confirmed || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    final snapshot = await loadWorkspace(widget.store);
    var deleted = 0;
    final failures = <String>[];

    for (final record in snapshot.records) {
      try {
        await widget.store.deleteAudit(record.id);
        deleted++;
      } catch (error) {
        failures.add('${record.id}: $error');
      }
    }

    widget.onDataChanged?.call();
    if (!mounted) return;
    await reload();

    messenger.showSnackBar(SnackBar(
      duration: const Duration(seconds: 8),
      content: Text(
        failures.isEmpty
            ? 'Deleted $deleted session(s).'
            : 'Deleted $deleted; ${failures.length} could not be removed — '
                '${failures.first}',
      ),
    ));
  }

  Future<bool> _confirm({
    required String title,
    required String body,
    required String action,
    bool destructive = false,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(
              action,
              style: destructive
                  ? TextStyle(color: Theme.of(context).colorScheme.error)
                  : null,
            ),
          ),
        ],
      ),
    );
    return result == true;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ShellPage(
      title: 'Settings',
      subtitle: 'Everything on this screen changes something real. There are no '
          'preferences here for features this build does not have.',
      actions: [
        IconButton(
          onPressed: _loading ? null : reload,
          tooltip: 'Refresh',
          icon: const Icon(Icons.refresh, size: 20),
        ),
      ],
      children: [
        SectionCard(
          title: 'Appearance',
          icon: Icons.palette_outlined,
          description: 'The Golden Taupe palette in light or dark. "System" '
              'follows the operating system.',
          child: SegmentedButton<ThemeMode>(
            segments: const [
              ButtonSegment(
                value: ThemeMode.light,
                icon: Icon(Icons.light_mode_outlined, size: 17),
                label: Text('Light'),
              ),
              ButtonSegment(
                value: ThemeMode.dark,
                icon: Icon(Icons.dark_mode_outlined, size: 17),
                label: Text('Dark'),
              ),
              ButtonSegment(
                value: ThemeMode.system,
                icon: Icon(Icons.contrast, size: 17),
                label: Text('System'),
              ),
            ],
            selected: {widget.themeMode},
            onSelectionChanged: (selection) =>
                widget.onThemeModeChanged(selection.first),
          ),
        ),
        const SizedBox(height: Spacing.xl),

        SectionCard(
          title: 'Storage',
          icon: Icons.save_outlined,
          tone: widget.storageIsDurable ? SectionTone.neutral : SectionTone.fault,
          description: widget.storageIsDurable
              ? 'Sessions are written to disk as inspectable JSON documents and '
                  'survive restarting the app.'
              : 'Nothing written here survives closing the app on this '
                  'platform.',
          child: Column(
            children: [
              KeyValueRow(
                label: 'Location',
                value: widget.storageLocation,
                monospaceValue: false,
              ),
              KeyValueRow(
                label: 'Durable',
                value: widget.storageIsDurable ? 'yes' : 'no',
                monospaceValue: false,
                tone: widget.storageIsDurable
                    ? context.evidence.verified
                    : theme.colorScheme.error,
              ),
              KeyValueRow(label: 'Stored sessions', value: '$_sessionCount'),
            ],
          ),
        ),
        const SizedBox(height: Spacing.xl),

        SectionCard(
          title: 'Enrolled reference face',
          icon: Icons.face_outlined,
          tone: _enrolmentError == null
              ? SectionTone.neutral
              : SectionTone.fault,
          description: 'Identity verification is mandatory for every session, so '
              'this is a precondition rather than a preference.',
          child: _loading
              ? const Row(
                  children: [
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(width: Spacing.md),
                    Expanded(child: Text('Checking…')),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_enrolmentError != null) ...[
                      InlineNotice(
                        tone: NoticeTone.fault,
                        message: 'A profile exists but could not be read: '
                            '$_enrolmentError. This is a fault, not "nobody has '
                            'enrolled" — discard it and enrol again.',
                      ),
                    ] else if (_enrolment == null)
                      Text(
                        'Nobody is enrolled. The next session will capture a '
                        'reference face before it begins.',
                        style: theme.textTheme.bodySmall,
                      )
                    else ...[
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Tag(
                          label: 'Enrolled',
                          icon: Icons.verified_user_outlined,
                          tone: context.evidence.verified,
                        ),
                      ),
                      const SizedBox(height: Spacing.md),
                      KeyValueRow(
                        label: 'Captured',
                        value: _stamp(_enrolment!.capturedAt),
                      ),
                      KeyValueRow(
                        label: 'Face size',
                        value: '${_enrolment!.faceSize} px²',
                      ),
                    ],
                    if (_enrolment != null || _enrolmentError != null) ...[
                      const SizedBox(height: Spacing.md),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: OutlinedButton.icon(
                          onPressed: _clearEnrolment,
                          icon: const Icon(Icons.delete_outline, size: 18),
                          label: const Text('Discard enrolment'),
                        ),
                      ),
                    ],
                  ],
                ),
        ),
        const SizedBox(height: Spacing.xl),

        SectionCard(
          title: 'Local claim reader',
          icon: Icons.memory_outlined,
          description: 'Resume reading runs on a model on this machine. No API '
              'key exists anywhere in this build, and no resume text leaves the '
              'device. If the model is unreachable the app falls back to text '
              'rules and says so on the analysis screen.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_extractorState == null)
                Text(
                  'Not checked in this session. The check runs the reader on one '
                  'known line, which is a stronger test than pinging a port.',
                  style: theme.textTheme.bodySmall,
                )
              else
                InlineNotice(
                  tone: _extractorState!.reachable
                      ? NoticeTone.info
                      : NoticeTone.caution,
                  icon: _extractorState!.reachable
                      ? Icons.check_circle_outline
                      : Icons.warning_amber,
                  message: _extractorState!.detail,
                ),
              const SizedBox(height: Spacing.md),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: _checkingExtractor ? null : _checkExtractor,
                  icon: _checkingExtractor
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.play_arrow_outlined, size: 18),
                  label: Text(
                    _checkingExtractor ? 'Checking…' : 'Check the reader now',
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: Spacing.xl),

        SectionCard(
          title: 'What this tool does not claim',
          icon: Icons.gavel_outlined,
          description: 'Stated here because it constrains what the rest of the '
              'app is allowed to show.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final line in const [
                'It produces no score, grade, ranking, or hire recommendation. '
                    'Every screen reports counts of observations and leaves the '
                    'decision entirely with you.',
                'It cannot detect dishonesty. "Not demonstrated" means a '
                    'response did not show a claim — people freeze, '
                    'misremember, and explain things badly under pressure.',
                'It never treats "could not measure" as a pass. An identity '
                    'check that failed to run is reported as unmeasured, in '
                    'its own colour, everywhere it appears.',
                'Its machine-learning components have never been fitted to real '
                    'candidate data. They are trained on synthetic data and the '
                    'model view says so on screen.',
              ])
                Padding(
                  padding: const EdgeInsets.only(bottom: Spacing.sm),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 6, right: Spacing.sm),
                        child: Container(
                          width: 5,
                          height: 5,
                          decoration: BoxDecoration(
                            color: theme.colorScheme.onSurfaceVariant,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Text(line, style: theme.textTheme.bodyMedium),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: Spacing.xl),

        SectionCard(
          title: 'Delete stored data',
          icon: Icons.warning_amber,
          tone: SectionTone.quiet,
          description: 'Irreversible. Export from Reports first if the records '
              'matter.',
          child: Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: _sessionCount == 0 ? null : _deleteAllSessions,
              icon: const Icon(Icons.delete_forever_outlined, size: 18),
              label: Text(
                _sessionCount == 0
                    ? 'No sessions stored'
                    : 'Delete all $_sessionCount session(s)',
              ),
            ),
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
