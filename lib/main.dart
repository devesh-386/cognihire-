import 'package:flutter/material.dart';

import 'core/claims/claim.dart';
import 'core/claims/claim_audit.dart';
import 'core/design/app_theme.dart';
import 'core/persistence/audit_store.dart';
import 'core/persistence/json_codec.dart';
import 'core/persistence/store_factory.dart';
import 'core/roles/role.dart';
import 'core/roles/role_store.dart';
import 'core/roles/role_store_factory.dart';
import 'core/session/session_draft.dart';
import 'core/verification/verification_result.dart';
import 'core/workspace/workspace_loader.dart';
import 'features/analysis/resume_analysis_screen.dart';
import 'features/audit/claim_audit_screen.dart';
import 'features/candidates/candidates_screen.dart';
import 'features/common/empty_state.dart';
import 'features/dashboard/dashboard_screen.dart';
import 'features/enrolment/enrolment_screen.dart';
import 'features/interview/interview_screen.dart';
import 'features/reports/reports_screen.dart';
import 'features/roles/roles_screen.dart';
import 'features/sessions/session_history_screen.dart';
import 'features/settings/settings_screen.dart';
import 'features/task/task_screen.dart';
import 'ui/app_shell.dart';
import 'ui/components.dart';
import 'ui/tokens.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Resolved once at startup and passed down. If storage cannot be opened at
  // all, the app still runs — it just says sessions will not be kept, rather
  // than accepting audits it is going to drop.
  AuditStore store;
  RoleStore roleStore;
  String location;
  bool durable;
  try {
    store = await createAuditStore();
    roleStore = await createRoleStore();
    location = await auditStorageLocation();
    durable = storageIsDurable;
  } catch (error) {
    store = InMemoryAuditStore();
    roleStore = InMemoryRoleStore();
    location = 'Storage unavailable ($error) — sessions will not be kept.';
    durable = false;
  }

  runApp(CogniHireApp(
    store: store,
    roleStore: roleStore,
    storageLocation: location,
    storageIsDurable: durable,
  ));
}

class CogniHireApp extends StatefulWidget {
  const CogniHireApp({
    super.key,
    required this.store,
    required this.roleStore,
    required this.storageLocation,
    required this.storageIsDurable,
  });

  final AuditStore store;
  final RoleStore roleStore;
  final String storageLocation;
  final bool storageIsDurable;

  @override
  State<CogniHireApp> createState() => _CogniHireAppState();
}

class _CogniHireAppState extends State<CogniHireApp> {
  // Held above MaterialApp rather than read from system settings once, so
  // Settings' light/dark/system control has something real to act on.
  ThemeMode _themeMode = ThemeMode.system;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CogniHire',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: _themeMode,
      home: HomeScreen(
        store: widget.store,
        roleStore: widget.roleStore,
        storageLocation: widget.storageLocation,
        storageIsDurable: widget.storageIsDurable,
        themeMode: _themeMode,
        onThemeModeChanged: (mode) => setState(() => _themeMode = mode),
      ),
    );
  }
}

/// Illustrative audit showing every reported state, including the ones that
/// admit a gap. Clearly labelled as sample data wherever it is offered.
ClaimAudit _sampleAudit() {
  final start = DateTime.now().subtract(const Duration(minutes: 38));
  final end = DateTime.now();

  return const ClaimAuditBuilder().build(
    claims: const [
      Claim(
        id: 'c1',
        text: 'Built and shipped a React dashboard used by 200+ staff',
        source: 'Resume, page 1',
        skill: 'React',
      ),
      Claim(
        id: 'c2',
        text: 'Optimised Postgres queries, cutting p95 latency by 60%',
        source: 'Resume, page 1',
        skill: 'PostgreSQL',
      ),
      Claim(
        id: 'c3',
        text: 'Led migration of CI pipeline to GitHub Actions',
        source: 'Cover letter',
        skill: 'CI/CD',
      ),
    ],
    evidenceByClaimId: {
      'c1': [
        ClaimEvidence(
          observation:
              'Asked to walk through component structure; described state '
              'lifting and why context was avoided for the filter panel.',
          kind: EvidenceKind.probeResponse,
          at: start.add(const Duration(minutes: 6)),
        ),
        ClaimEvidence(
          observation:
              'Answer written incrementally over 4m12s, 31% revision ratio.',
          kind: EvidenceKind.processSignal,
          at: start.add(const Duration(minutes: 10)),
        ),
      ],
      'c2': [
        ClaimEvidence(
          observation:
              '340 characters were added in one step, then explained on '
              'request: described the index choice but not the measurement '
              'method behind the 60% figure.',
          kind: EvidenceKind.probeResponse,
          at: start.add(const Duration(minutes: 21)),
        ),
      ],
    },
    reviewerAssessments: const {'c1': ClaimStatus.substantiated},
    identityAttempts: [
      Verified(similarity: 96.4, at: start.add(const Duration(minutes: 1))),
      Verified(similarity: 95.1, at: start.add(const Duration(minutes: 8))),
      Unchecked(
        reason: UncheckedReason.noFaceInFrame,
        at: start.add(const Duration(minutes: 15)),
      ),
      Verified(similarity: 94.8, at: start.add(const Duration(minutes: 24))),
      Verified(similarity: 96.9, at: start.add(const Duration(minutes: 33))),
    ],
    sessionStart: start,
    sessionEnd: end,
  );
}

/// Stands in for [RoleStore] when a caller has not supplied one — most
/// existing test and preview call sites predate the Roles feature. Reports an
/// empty list rather than throwing, and refuses writes with a message that
/// says why, rather than silently discarding a role someone typed.
class _NoRoleStore implements RoleStore {
  const _NoRoleStore();

  @override
  Future<RoleIndex> listRoles() async => const RoleIndex(roles: [], problem: null);

  @override
  Future<void> saveRole(Role role) => throw UnsupportedError(
        'No role store was supplied to this HomeScreen.',
      );

  @override
  Future<void> deleteRole(String id) => throw UnsupportedError(
        'No role store was supplied to this HomeScreen.',
      );
}

/// Entry point: nine destinations behind one persistent rail. What exists is
/// what is in the rail — see `ui/app_shell.dart` for why that rule exists and
/// what it has already caught.
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.store,
    RoleStore? roleStore,
    required this.storageLocation,
    required this.storageIsDurable,
    this.themeMode = ThemeMode.system,
    this.onThemeModeChanged,
  }) : roleStore = roleStore ?? const _NoRoleStore();

  final AuditStore store;

  /// Defaults to an inert store when the caller does not supply one — most
  /// existing call sites (tests, previews) predate the Roles feature and have
  /// no opinion about role persistence.
  final RoleStore roleStore;

  final String storageLocation;
  final bool storageIsDurable;
  final ThemeMode themeMode;

  /// Null when the caller has nowhere to persist a theme choice — Settings'
  /// appearance control is then simply not wired to anything durable, rather
  /// than the screen requiring a callback every test would otherwise have to
  /// invent.
  final ValueChanged<ThemeMode>? onThemeModeChanged;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  /// Shared across the setup screen and the resume-analysis screen — see
  /// `core/session/session_draft.dart` for why this has to be one object
  /// rather than state duplicated in each screen.
  final _draft = SessionDraft();

  EnrolmentProfile? _enrolment;

  /// Set when a stored enrolment exists but cannot be read. Kept distinct from
  /// "not enrolled": one is a choice, the other is a fault, and running a
  /// session unverified because of a fault should never look deliberate.
  String? _enrolmentError;

  bool _loadingEnrolment = true;

  /// Roles available to pick for the session being set up. Loaded once and
  /// refreshed by [_refreshWorkspaceViews], same as the other workspace-derived
  /// views — a role saved or deleted on the Roles screen should be reflected
  /// here without the operator having to leave and come back.
  RoleIndex? _roleIndex;

  final _dashboardKey = GlobalKey<DashboardScreenState>();
  final _candidatesKey = GlobalKey<CandidatesScreenState>();
  final _reportsKey = GlobalKey<ReportsScreenState>();
  final _rolesKey = GlobalKey<RolesScreenState>();
  final _settingsKey = GlobalKey<SettingsScreenState>();

  @override
  void initState() {
    super.initState();
    _loadEnrolment();
    _loadRoles();
  }

  Future<void> _loadRoles() async {
    final index = await widget.roleStore.listRoles();
    if (!mounted) return;
    setState(() => _roleIndex = index);

    // A role the draft was pointing at may have been deleted since this list
    // last loaded — the session setup should not go on silently ordering
    // claims against a role that no longer exists.
    final current = _draft.targetRole;
    if (current == null) return;
    final stillExists = index.roles.any((r) => r.id == current.id);
    if (!stillExists) _draft.targetRole = null;
  }

  @override
  void dispose() {
    _draft.dispose();
    super.dispose();
  }

  Future<void> _loadEnrolment() async {
    setState(() => _loadingEnrolment = true);
    try {
      final profile = await widget.store.loadEnrolment();
      if (!mounted) return;
      setState(() {
        _enrolment = profile;
        _enrolmentError = null;
        _loadingEnrolment = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _enrolment = null;
        _enrolmentError = '$error';
        _loadingEnrolment = false;
      });
    }
  }

  /// Called after a session ends, or after data-changing actions in Settings,
  /// so every other screen's numbers reflect what just happened rather than
  /// what was true when they last loaded.
  void _refreshWorkspaceViews() {
    _dashboardKey.currentState?.reload();
    _candidatesKey.currentState?.reload();
    _reportsKey.currentState?.reload();
    _rolesKey.currentState?.reload();
    _settingsKey.currentState?.reload();
    _loadRoles();
  }

  /// Starts a session against an already-enrolled reference.
  ///
  /// Takes a non-null embedding by design: enrolment is a precondition for
  /// running at all, so there is no unverified path to reach this from.
  void _startInterview(List<double> embedding) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => InterviewScreen(
          claims: _draft.effectiveClaims,
          enrolledEmbedding: embedding,
          store: widget.store,
          candidateLabel: _draft.label,
          researchConsentGranted: _draft.researchConsent,
        ),
      ),
    ).then((_) => _refreshWorkspaceViews());
  }

  /// Capture a fresh reference face, keep it, then go straight into the
  /// session.
  void _enrolThenInterview() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => EnrolmentScreen(
          onEnrolled: (capture) async {
            final profile = EnrolmentProfile(
              embedding: capture.embedding,
              capturedAt: DateTime.now(),
              faceSize: capture.faceSize,
            );

            String? saveError;
            try {
              await widget.store.saveEnrolment(profile);
            } catch (error) {
              saveError = '$error';
            }

            if (!mounted) return;
            setState(() {
              _enrolment = profile;
              _enrolmentError = null;
            });

            final messenger = ScaffoldMessenger.of(context);
            // Replace enrolment so back-navigation cannot land on a screen
            // still holding the camera.
            Navigator.of(context).pushReplacement(
              MaterialPageRoute(
                builder: (_) => InterviewScreen(
                  claims: _draft.effectiveClaims,
                  enrolledEmbedding: capture.embedding,
                  store: widget.store,
                  candidateLabel: _draft.label,
                  researchConsentGranted: _draft.researchConsent,
                ),
              ),
            ).then((_) => _refreshWorkspaceViews());

            if (saveError != null) {
              messenger.showSnackBar(SnackBar(
                duration: const Duration(seconds: 6),
                content: Text(
                  'Enrolment used for this session but not saved: $saveError',
                ),
              ));
            }
          },
        ),
      ),
    );
  }

  Future<void> _clearEnrolment() async {
    await widget.store.clearEnrolment();
    if (!mounted) return;
    setState(() {
      _enrolment = null;
      _enrolmentError = null;
    });
  }

  void _goToNewSession() =>
      AppShellController.of(context)?.goTo('New session');

  /// Built once. The sample audit is stamped with wall-clock times, so
  /// rebuilding it on every frame would make its timestamps drift and its
  /// widgets churn for no reason.
  late final ClaimAudit _sample = _sampleAudit();

  @override
  Widget build(BuildContext context) {
    final notices = <ShellNotice>[
      if (!widget.storageIsDurable)
        ShellNotice(
          title: 'Storage is not durable',
          detail: widget.storageLocation,
          tone: ShellNoticeTone.caution,
          onTap: () => AppShellController.of(context)?.goTo('Settings'),
        ),
      if (_enrolmentError != null)
        ShellNotice(
          title: 'Enrolled face is unreadable',
          detail: _enrolmentError!,
          tone: ShellNoticeTone.fault,
          onTap: () => AppShellController.of(context)?.goTo('Settings'),
        ),
    ];

    return AppShell(
      title: 'CogniHire',
      tagline: 'Verified-claim interviewing',
      primaryAction: ShellPrimaryAction(
        label: 'New session',
        icon: Icons.add,
        onPressed: _goToNewSession,
      ),
      identity: ShellIdentity(
        name: _draft.label,
        role: 'Session operator',
        onTap: () => AppShellController.of(context)?.goTo('Settings'),
      ),
      notices: notices,
      onHelp: () => AppShellController.of(context)?.goTo('Settings'),
      onSearch: (query) {
        AppShellController.of(context)?.goTo('Candidates');
        _candidatesKey.currentState?.applyQuery(query);
      },
      destinations: [
        ShellDestination(
          icon: Icons.dashboard_outlined,
          selectedIcon: Icons.dashboard,
          label: 'Dashboard',
          builder: (_) => DashboardScreen(
            key: _dashboardKey,
            store: widget.store,
            storageLocation: widget.storageLocation,
            storageIsDurable: widget.storageIsDurable,
            onStartSession: _goToNewSession,
          ),
        ),
        ShellDestination(
          icon: Icons.people_outline,
          selectedIcon: Icons.people,
          label: 'Candidates',
          builder: (_) => CandidatesScreen(
            key: _candidatesKey,
            store: widget.store,
            onStartSession: _goToNewSession,
          ),
        ),
        ShellDestination(
          icon: Icons.work_outline,
          selectedIcon: Icons.work,
          label: 'Roles',
          builder: (_) => RolesScreen(
            key: _rolesKey,
            roleStore: widget.roleStore,
            loadSessions: () => loadWorkspace(widget.store),
          ),
        ),
        ShellDestination(
          icon: Icons.play_circle_outline,
          selectedIcon: Icons.play_circle_fill,
          label: 'New session',
          shortLabel: 'New',
          builder: _setupPage,
        ),
        ShellDestination(
          icon: Icons.document_scanner_outlined,
          selectedIcon: Icons.document_scanner,
          label: 'Resume analysis',
          shortLabel: 'Resume',
          builder: (_) => ResumeAnalysisScreen(draft: _draft),
        ),
        ShellDestination(
          icon: Icons.history_outlined,
          selectedIcon: Icons.history,
          label: 'Sessions',
          builder: (_) => SessionHistoryScreen(
            store: widget.store,
            storageLocation: widget.storageLocation,
            storageIsDurable: widget.storageIsDurable,
          ),
        ),
        ShellDestination(
          icon: Icons.summarize_outlined,
          selectedIcon: Icons.summarize,
          label: 'Reports',
          builder: (_) => ReportsScreen(
            key: _reportsKey,
            store: widget.store,
            sampleAudit: () => ClaimAuditScreen(
              audit: _sample,
              label: 'Sample audit — illustrative data, not a real candidate',
            ),
            onStartSession: _goToNewSession,
          ),
        ),
        ShellDestination(
          icon: Icons.monitor_heart_outlined,
          selectedIcon: Icons.monitor_heart,
          label: 'Telemetry',
          builder: (_) => const TaskScreen(),
        ),
        ShellDestination(
          icon: Icons.settings_outlined,
          selectedIcon: Icons.settings,
          label: 'Settings',
          builder: (_) => SettingsScreen(
            key: _settingsKey,
            store: widget.store,
            storageLocation: widget.storageLocation,
            storageIsDurable: widget.storageIsDurable,
            themeMode: widget.themeMode,
            onThemeModeChanged: widget.onThemeModeChanged ?? (_) {},
            onDataChanged: () {
              _loadEnrolment();
              _refreshWorkspaceViews();
            },
          ),
        ),
      ],
    );
  }

  Widget _setupPage(BuildContext context) {
    final theme = Theme.of(context);

    return AnimatedBuilder(
      animation: _draft,
      builder: (context, _) => ShellPage(
        title: 'New session',
        subtitle:
            'Continuous provenance for technical interviews — who did the '
            'work, how, and what could not be checked.',
        maxWidth: Measures.form,
        children: [
          SectionCard(
            title: 'Candidate',
            icon: Icons.badge_outlined,
            description: 'How this session is filed in Sessions and grouped in '
                'Candidates.',
            child: TextField(
              onChanged: (value) => _draft.label = value,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(
                labelText: 'Candidate reference',
                hintText: 'e.g. Alice Nguyen — backend screen',
              ),
            ),
          ),
          const SizedBox(height: Spacing.md),
          _enrolmentCard(theme),
          const SizedBox(height: Spacing.md),
          _rolePickerCard(theme),
          const SizedBox(height: Spacing.md),
          _claimsSummaryCard(context),
          const SizedBox(height: Spacing.md),
          _researchConsentTile(theme),
          const SizedBox(height: Spacing.xl),

          // One action. Enrolment is a precondition, so there is no second,
          // unverified way in.
          SectionCard(
            title: 'Start',
            icon: Icons.verified_user_outlined,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FilledButton.icon(
                  onPressed: _enrolment == null
                      ? _enrolThenInterview
                      : () => _startInterview(_enrolment!.embedding),
                  icon: const Icon(Icons.verified_user_outlined, size: 19),
                  label: Text(
                    _enrolment == null
                        ? 'Enrol and start verified interview'
                        : 'Start verified interview',
                  ),
                ),
                const SizedBox(height: Spacing.sm),
                Text(
                  _enrolment == null
                      ? 'A reference face is captured first. Every session '
                          'runs with identity verification — there is no '
                          'unverified mode.'
                      : 'Identity is re-checked throughout the session. '
                          'Checks that cannot be performed are reported as '
                          'unmeasured, never as passes.',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),

          if (!widget.storageIsDurable) ...[
            const SizedBox(height: Spacing.xl),
            _storageNotice(theme),
          ],
        ],
      ),
    );
  }

  /// Optional — a session runs without a role picked, same as before this
  /// existed. Picking one only reorders which claim opens first (see
  /// `orderClaimsForRole`'s doc); it adds nothing to the audit and changes no
  /// verdict.
  Widget _rolePickerCard(ThemeData theme) {
    final roles = _roleIndex?.roles ?? const <Role>[];

    return SectionCard(
      title: 'Role this session is screening for',
      icon: Icons.work_outline,
      description: roles.isEmpty
          ? 'No roles defined yet. Add one on the Roles screen to have this '
              "session probe that role's required skills first."
          : 'Optional. Reorders the claim queue so this role\'s required '
              'skills are examined before the rest — every claim is still '
              'asked about, nothing is dropped.',
      child: roles.isEmpty
          ? const SizedBox.shrink()
          : DropdownButtonFormField<String>(
              initialValue: _draft.targetRole?.id,
              decoration: const InputDecoration(
                labelText: 'Role (optional)',
              ),
              items: [
                const DropdownMenuItem(value: null, child: Text('None')),
                for (final role in roles)
                  DropdownMenuItem(value: role.id, child: Text(role.title)),
              ],
              onChanged: (id) => setState(() {
                _draft.targetRole =
                    id == null ? null : roles.firstWhere((r) => r.id == id);
              }),
            ),
    );
  }

  Widget _claimsSummaryCard(BuildContext context) {
    final theme = Theme.of(context);
    final role = _draft.targetRole;

    return SectionCard(
      title: 'Claims this session will examine',
      icon: Icons.fact_check_outlined,
      trailing: TextButton(
        onPressed: () => AppShellController.of(context)?.goTo('Resume analysis'),
        child: Text(_draft.usingDemoClaims ? 'Add a resume' : 'Review'),
      ),
      description: [
        if (_draft.usingDemoClaims)
          'No resume has been confirmed yet, so this session would run on '
              'two labelled demo claims.'
        else
          '${_draft.confirmedClaims.length} claim(s) confirmed from the '
              "candidate's own resume on the Resume analysis screen.",
        if (role != null)
          'Ordered with "${role.title}"\'s required skills first.',
      ].join(' '),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final claim in _draft.effectiveClaims)
            Padding(
              padding: const EdgeInsets.only(bottom: Spacing.xs),
              child: Text(
                '· ${claim.text}',
                style: theme.textTheme.bodyMedium,
              ),
            ),
        ],
      ),
    );
  }

  Widget _storageNotice(ThemeData theme) => Card(
        color: theme.colorScheme.errorContainer,
        child: Padding(
          padding: const EdgeInsets.all(Spacing.lg),
          child: _statusRow(
            theme,
            icon: Icons.warning_amber,
            label: 'Storage is not durable on this platform',
            value: widget.storageLocation,
            note: 'Sessions will not survive closing the app.',
            tone: theme.colorScheme.error,
          ),
        ),
      );

  Widget _statusRow(
    ThemeData theme, {
    required IconData icon,
    required String label,
    required String value,
    required String note,
    Color? tone,
  }) =>
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            icon,
            size: 17,
            color: tone ?? theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: Spacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: theme.textTheme.labelMedium?.copyWith(color: tone),
                ),
                SelectableText(value, style: theme.textTheme.bodySmall),
                Text(note, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
        ],
      );

  /// A second, separate consent from identity verification — this one governs
  /// research-release use of the session's data, not whether the session can
  /// run at all. Opt-in and unchecked by default: the checkbox is the whole
  /// mechanism, there is no "ask me later" state that quietly defaults to yes.
  Widget _researchConsentTile(ThemeData theme) => Card(
        child: CheckboxListTile(
          value: _draft.researchConsent,
          onChanged: (checked) => _draft.researchConsent = checked ?? false,
          controlAffinity: ListTileControlAffinity.leading,
          title: const Text('Allow this session for research release'),
          subtitle: Text(
            'Separate from identity verification, which always runs. If '
            'checked, this session may be included in the de-identified '
            'research dataset. The choice is recorded either way.',
            style: theme.textTheme.bodySmall,
          ),
        ),
      );

  Widget _enrolmentCard(ThemeData theme) {
    if (_loadingEnrolment) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(Spacing.lg),
          child: Row(
            children: [
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: Spacing.md),
              // Expanded so the message wraps within the card on a narrow
              // window rather than pushing past the row's right edge.
              Expanded(
                child: Text(
                  'Checking for a saved reference face…',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ],
          ),
        ),
      );
    }

    // An unreadable profile is a fault, and is shown as one. It must not be
    // mistaken for "nobody has enrolled".
    if (_enrolmentError != null) {
      return Card(
        color: theme.colorScheme.errorContainer,
        child: Padding(
          padding: const EdgeInsets.all(Spacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              StatusChip(
                icon: Icons.error_outline,
                label: 'Enrolment unreadable',
                colour: theme.colorScheme.error,
              ),
              const SizedBox(height: Spacing.md),
              Text(_enrolmentError!, style: theme.textTheme.bodySmall),
              const SizedBox(height: Spacing.xs),
              Text(
                'This is a fault, not "nobody has enrolled". Re-enrol before '
                'running a verified session.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: Spacing.sm),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: _clearEnrolment,
                  child: const Text('Discard it'),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final profile = _enrolment;
    if (profile == null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(Spacing.lg),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.person_outline,
                size: 18,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: Spacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'No reference face enrolled',
                      style: theme.textTheme.titleSmall,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Starting a verified interview will capture one first.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Spacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            StatusChip(
              icon: Icons.verified_user_outlined,
              label: 'Reference face enrolled',
              colour: context.evidence.verified,
            ),
            const SizedBox(height: Spacing.md),
            Text(
              'Captured ${_formatDate(profile.capturedAt)} · '
              'face size ${profile.faceSize}px²',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: Spacing.xs),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: _enrolThenInterview,
                  child: const Text('Re-enrol'),
                ),
                TextButton(
                  onPressed: _clearEnrolment,
                  child: const Text('Clear'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _formatDate(DateTime time) {
    final local = time.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }
}
