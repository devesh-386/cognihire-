import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

import 'core/auth/auth_store.dart';
import 'core/auth/principal.dart';
import 'core/auth/supabase_auth_store.dart';
import 'core/auth/user_role.dart';
import 'core/candidates/candidate_store.dart';
import 'core/candidates/candidate_store_supabase.dart';
import 'core/claims/claim.dart';
import 'core/config.dart';
import 'core/email/email_sender.dart';
import 'core/email/gmail_smtp_email_sender.dart';
import 'core/claims/claim_audit.dart';
import 'core/design/app_theme.dart';
import 'core/intakes/intake.dart';
import 'core/intakes/intake_store.dart';
import 'core/intakes/intake_store_supabase.dart';
import 'core/persistence/audit_store.dart';
import 'core/persistence/store_factory.dart';
import 'core/roles/role.dart';
import 'core/roles/role_store.dart';
import 'core/roles/role_store_supabase.dart';
import 'core/verification/verification_result.dart';
import 'core/workspace/workspace_loader.dart';
import 'features/auth/sign_in_screen.dart';
import 'core/invitations/invitation.dart';
import 'core/invitations/invitation_store.dart';
import 'core/invitations/invitation_store_supabase.dart';
import 'features/audit/claim_audit_screen.dart';
import 'features/candidates/candidates_screen.dart';
import 'features/dashboard/dashboard_screen.dart';
import 'features/demo/demo_screen.dart';
import 'features/interview_sessions/interview_sessions_screen.dart';
import 'features/invitations/invitations_screen.dart';
import 'features/reports/reports_screen.dart';
import 'features/roles/roles_screen.dart';
import 'features/sessions/session_history_screen.dart';
import 'features/settings/settings_screen.dart';
import 'features/task/task_screen.dart';
import 'ui/app_shell.dart';
import 'ui/patterns.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Ticket 10: roles and invitations now live in the shared `cognihire`
  // Supabase project (org-scoped by RLS) instead of local JSON/in-memory —
  // see role_store_supabase.dart / invitation_store_supabase.dart for why the
  // interfaces themselves didn't need to change.
  await supabase.Supabase.initialize(
    url: AppConfig.supabaseUrl,
    publishableKey: AppConfig.supabaseAnonKey,
  );
  final client = supabase.Supabase.instance.client;
  final authStore = SupabaseAuthStore(client);
  final roleStore = SupabaseRoleStore(client);
  final intakeStore = SupabaseIntakeStore(client);
  final candidateStore = SupabaseCandidateStore(client);
  final invitationStore = SupabaseInvitationStore(client);

  // Claim audits (interview reports) are unaffected by this ticket and stay
  // local/durable-JSON for now — that migration is a later ticket.
  AuditStore store;
  String location;
  bool durable;
  try {
    store = await createAuditStore();
    location = await auditStorageLocation();
    durable = storageIsDurable;
  } catch (error) {
    store = InMemoryAuditStore();
    location = 'Storage unavailable ($error) — sessions will not be kept.';
    durable = false;
  }

  final emailSender = _createEmailSender();

  runApp(CogniHireApp(
    store: store,
    roleStore: roleStore,
    intakeStore: intakeStore,
    candidateStore: candidateStore,
    invitationStore: invitationStore,
    authStore: authStore,
    provisionOrganization: (name) =>
        _provisionOrganization(client, authStore, name),
    emailSender: emailSender,
    storageLocation: location,
    storageIsDurable: durable,
  ));
}

/// Calls the `provision_organization` RPC (Ticket 8's
/// `role_delete_policy_and_org_provisioning` migration, corrected by
/// `0014_provision_organization_app_metadata.sql`) for a freshly registered
/// recruiter, then refreshes the session so the client's JWT picks up the
/// `organization_id` the RPC just stamped into `auth.users.raw_app_meta_data`
/// — see `SupabaseAuthStore`'s doc comment on why role/org live in
/// `app_metadata`, not `user_metadata`. Returns null on any failure rather
/// than throwing, matching every other [AuthStore] failure path's "never
/// crash the sign-in screen" rule.
///
/// Currently unreachable from the UI — see `sign_in_screen.dart`'s
/// `_openBrowserRegistration`, which sends recruiter registration to the web
/// portal instead. Kept working (not deleted) because it's still a real,
/// directly callable Supabase RPC reachable by anyone holding the shipped
/// anon key and any signed-in session, whether or not this app's UI ever
/// invokes it.
Future<Principal?> _provisionOrganization(
  supabase.SupabaseClient client,
  SupabaseAuthStore authStore,
  String organizationName,
) async {
  try {
    await client.rpc('provision_organization', params: {
      'org_name': organizationName,
    });
    await client.auth.refreshSession();
    return authStore.current;
  } catch (_) {
    return null;
  }
}

/// A real [GmailSmtpEmailSender] when launched with both dart-defines set,
/// otherwise [NullEmailSender] — which fails every send with an actionable
/// reason rather than the app crashing or silently pretending to send.
/// `String.fromEnvironment` reads `--dart-define`, so the credential never
/// touches source control; see `GmailSmtpEmailSender`'s doc for the security
/// tradeoff of it living in this client process at all.
EmailSender _createEmailSender() {
  const address = String.fromEnvironment('GMAIL_ADDRESS');
  const appPassword = String.fromEnvironment('GMAIL_APP_PASSWORD');
  if (address.isEmpty || appPassword.isEmpty) return const NullEmailSender();
  return GmailSmtpEmailSender(address: address, appPassword: appPassword);
}

class CogniHireApp extends StatefulWidget {
  const CogniHireApp({
    super.key,
    required this.store,
    required this.roleStore,
    required this.intakeStore,
    required this.candidateStore,
    required this.invitationStore,
    required this.authStore,
    required this.emailSender,
    required this.storageLocation,
    required this.storageIsDurable,
    this.provisionOrganization,
  });

  final AuditStore store;
  final RoleStore roleStore;
  final IntakeStore intakeStore;
  final CandidateStore candidateStore;
  final InvitationStore invitationStore;
  final AuthStore authStore;
  final Future<Principal?> Function(String organizationName)?
      provisionOrganization;
  final EmailSender emailSender;
  final String storageLocation;
  final bool storageIsDurable;

  @override
  State<CogniHireApp> createState() => _CogniHireAppState();
}

class _CogniHireAppState extends State<CogniHireApp> {
  // Held above MaterialApp rather than read from system settings once, so
  // Settings' light/dark/system control has something real to act on.
  ThemeMode _themeMode = ThemeMode.system;

  /// The signed-in person, or null when nobody has chosen a role yet. This is
  /// the single gate between the sign-in chooser and the app: null shows the
  /// chooser, non-null mounts that role's experience.
  Principal? _principal;

  /// Set only when [_principal] is a candidate who entered through a redeemed
  /// invitation code. Carried through to [HomeScreen] so the session it sets up
  /// starts already bound to that invitation's role, instead of the candidate
  /// having to find it again in a dropdown.
  Invitation? _redeemedInvitation;

  /// True until [AuthStore.restore] has answered once. `SupabaseAuthStore`
  /// already persists a session to disk and restores it during
  /// `Supabase.initialize()` in `main()` — [AuthStore.restore]'s own doc
  /// comment says as much — but nothing was ever calling it, so a returning
  /// user always landed back on the sign-in chooser regardless. Held as
  /// separate state rather than folded into `_principal == null` so the
  /// chooser never flashes on screen for the half-second before restore
  /// answers.
  bool _restoring = true;

  @override
  void initState() {
    super.initState();
    widget.authStore.restore().then((principal) {
      if (!mounted) return;
      setState(() {
        _principal = principal;
        _restoring = false;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CogniHire',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: _themeMode,
      home: _restoring
          ? const _RestoringSplash()
          : _principal == null
          ? SignInScreen(
              invitationStore: widget.invitationStore,
              authStore: widget.authStore,
              provisionOrganization: widget.provisionOrganization,
              onSignIn: (p, invitation) => setState(() {
                _principal = p;
                _redeemedInvitation = invitation;
              }),
            )
          : HomeScreen(
              // Keyed by principal id so switching accounts rebuilds the shell
              // from scratch rather than leaking the previous person's state.
              key: ValueKey(_principal!.id),
              store: widget.store,
              roleStore: widget.roleStore,
              intakeStore: widget.intakeStore,
              candidateStore: widget.candidateStore,
              invitationStore: widget.invitationStore,
              emailSender: widget.emailSender,
              redeemedInvitation: _redeemedInvitation,
              storageLocation: widget.storageLocation,
              storageIsDurable: widget.storageIsDurable,
              themeMode: _themeMode,
              onThemeModeChanged: (mode) => setState(() => _themeMode = mode),
              principal: _principal,
              onSignOut: () => setState(() {
                _principal = null;
                _redeemedInvitation = null;
              }),
            ),
    );
  }
}

/// Shown for the single frame or two [AuthStore.restore] takes to answer.
/// Deliberately not a bare spinner on a blank white page — that reads as a
/// crash for the instant before it resolves, on a screen the returning user
/// (the common case now that restore actually runs) sees every launch.
class _RestoringSplash extends StatelessWidget {
  const _RestoringSplash();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
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

/// Stands in for [IntakeStore] when a caller has not supplied one, for the
/// same reason [_NoRoleStore] does.
class _NoIntakeStore implements IntakeStore {
  const _NoIntakeStore();

  @override
  Future<List<Intake>> listForRole(String roleId) async => const [];

  @override
  Future<Intake> create({required String roleId, required String name}) =>
      throw UnsupportedError('No intake store was supplied to this HomeScreen.');

  @override
  Future<void> updateStatus(String intakeId, IntakeStatus status) =>
      throw UnsupportedError('No intake store was supplied to this HomeScreen.');
}

/// Stands in for [InvitationStore] when a caller has not supplied one, for the
/// same reason [_NoRoleStore] does: pre-Invitations call sites (tests,
/// previews) have no opinion about it.
class _NoInvitationStore implements InvitationStore {
  const _NoInvitationStore();

  @override
  Future<InvitationIndex> listInvitations() async =>
      const InvitationIndex(invitations: [], problem: null);

  @override
  Future<void> saveInvitation(Invitation invitation) => throw UnsupportedError(
        'No invitation store was supplied to this HomeScreen.',
      );

  @override
  Future<Invitation?> findRedeemable(String code) async => null;

  @override
  Future<void> revokeInvitation(Invitation invitation) => throw UnsupportedError(
        'No invitation store was supplied to this HomeScreen.',
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
    IntakeStore? intakeStore,
    this.candidateStore = const InMemoryCandidateStore(),
    InvitationStore? invitationStore,
    this.emailSender = const NullEmailSender(),
    required this.storageLocation,
    required this.storageIsDurable,
    this.themeMode = ThemeMode.system,
    this.onThemeModeChanged,
    this.principal,
    this.onSignOut,
    this.redeemedInvitation,
    this.clock,
  })  : roleStore = roleStore ?? const _NoRoleStore(),
        intakeStore = intakeStore ?? const _NoIntakeStore(),
        invitationStore = invitationStore ?? const _NoInvitationStore();

  final AuditStore store;

  /// Passed to [DashboardScreen] so the preview goldens can pin the
  /// time-of-day greeting. Null everywhere but those tests — see
  /// `DashboardScreen.clock`.
  final DateTime Function()? clock;

  /// The signed-in person, when the app was entered through the sign-in
  /// chooser. Optional because most existing call sites (tests, previews)
  /// mount the shell directly without an auth gate; the shell falls back to its
  /// generic operator identity when this is null.
  final Principal? principal;

  /// Returns to the sign-in chooser. Null for the direct-mount call sites above.
  final VoidCallback? onSignOut;

  /// Set when [principal] is a candidate who entered through a redeemed
  /// invitation code. The session draft is pre-bound to this invitation's
  /// candidate name and role on first build — see `_HomeScreenState.initState`.
  final Invitation? redeemedInvitation;

  /// Defaults to an inert store when the caller does not supply one — most
  /// existing call sites (tests, previews) predate the Roles feature and have
  /// no opinion about role persistence.
  final RoleStore roleStore;

  /// Defaults to an inert store when the caller does not supply one, for the
  /// same reason [roleStore] does.
  final IntakeStore intakeStore;

  /// Defaults to an empty in-memory store when the caller does not supply
  /// one — unlike [roleStore]/[intakeStore], reading it never throws (there
  /// is no write path here for a test/preview call site to need to refuse).
  final CandidateStore candidateStore;

  /// Defaults to an inert store when the caller does not supply one, for the
  /// same reason [roleStore] does.
  final InvitationStore invitationStore;

  /// Defaults to [NullEmailSender] — most call sites (tests, previews) have
  /// no opinion about email, and the real app itself falls back to it too
  /// when no Gmail credential was supplied at launch. See `_createEmailSender`.
  final EmailSender emailSender;

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
  final _dashboardKey = GlobalKey<DashboardScreenState>();
  final _candidatesKey = GlobalKey<CandidatesScreenState>();
  final _reportsKey = GlobalKey<ReportsScreenState>();
  final _rolesKey = GlobalKey<RolesScreenState>();
  final _invitationsKey = GlobalKey<InvitationsScreenState>();
  final _settingsKey = GlobalKey<SettingsScreenState>();

  /// Called after a session ends, or after data-changing actions in Settings,
  /// so every other screen's numbers reflect what just happened rather than
  /// what was true when they last loaded.
  void _refreshWorkspaceViews() {
    _dashboardKey.currentState?.reload();
    _candidatesKey.currentState?.reload();
    _reportsKey.currentState?.reload();
    _rolesKey.currentState?.reload();
    _invitationsKey.currentState?.reload();
    _settingsKey.currentState?.reload();
  }

  void _goToInvitations() =>
      AppShellController.of(context)?.goTo('Invitations');

  /// Confirms, then returns to the sign-in chooser. Confirmed because signing
  /// out is a context switch a stray tap on the identity chip should not cause
  /// mid-session.
  Future<void> _confirmSignOut() async {
    final signOut = widget.onSignOut;
    if (signOut == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text('You will return to the sign-in screen.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
    if (confirmed == true) signOut();
  }

  /// Built once. The sample audit is stamped with wall-clock times, so
  /// rebuilding it on every frame would make its timestamps drift and its
  /// widgets churn for no reason.
  late final ClaimAudit _sample = _sampleAudit();

  /// Whether a destination for [roles] should appear for the signed-in person.
  ///
  /// A null principal means the shell was mounted directly (tests, previews)
  /// without going through the sign-in gate — those call sites expect the whole
  /// destination set, so nothing is filtered. Once someone has signed in, each
  /// role sees only its own navigation.
  bool _showFor(Set<UserRole> roles) {
    final role = widget.principal?.role;
    return role == null || roles.contains(role);
  }

  // Which experience each destination belongs to.
  static const _hr = {UserRole.recruiter};
  static const _both = {UserRole.recruiter, UserRole.candidate};

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
    ];

    return AppShell(
      title: 'CogniHire',
      tagline: 'Verified-claim interviewing',
      // Recruiter-only app: the candidate interview now runs entirely on the
      // web candidate portal, so there is no in-app "start a session" action.
      primaryAction: _showFor(_hr)
          ? ShellPrimaryAction(
              label: 'Invite candidate',
              icon: Icons.add,
              onPressed: _goToInvitations,
            )
          : null,
      identity: ShellIdentity(
        name: widget.principal?.displayName ??
            widget.principal?.email ??
            'Recruiter',
        role: widget.principal?.role.label ?? 'Session operator',
        onTap: widget.onSignOut == null
            ? () => AppShellController.of(context)?.goTo('Settings')
            : _confirmSignOut,
      ),
      notices: notices,
      onHelp: () => AppShellController.of(context)?.goTo('Settings'),
      // Search jumps to the Candidates directory, which only HR has.
      onSearch: _showFor(_hr)
          ? (query) {
              AppShellController.of(context)?.goTo('Candidates');
              _candidatesKey.currentState?.applyQuery(query);
            }
          : null,
      destinations: [
        if (_showFor(_hr))
          ShellDestination(
          icon: Icons.dashboard_outlined,
          selectedIcon: Icons.dashboard,
          label: 'Dashboard',
          builder: (_) => DashboardScreen(
            key: _dashboardKey,
            store: widget.store,
            storageLocation: widget.storageLocation,
            storageIsDurable: widget.storageIsDurable,
            onStartSession: _goToInvitations,
            clock: widget.clock,
            onOpenRoles: () => AppShellController.of(context)?.goTo('Roles'),
            onOpenInvitations: _goToInvitations,
            onOpenSessions: () =>
                AppShellController.of(context)?.goTo('Sessions'),
            onOpenReports: () =>
                AppShellController.of(context)?.goTo('Reports'),
            onOpenInterviews: () =>
                AppShellController.of(context)?.goTo('AI Interviews'),
            onOpenSettings: () =>
                AppShellController.of(context)?.goTo('Settings'),
            // Demo and Telemetry lost their permanent rail slots (CH — "the
            // dashboard is dead" feedback) but not the capability — Demo is
            // the one-click seed that actually populates this dashboard with
            // real data, and Telemetry is the shipped differentiator, not a
            // dev tool. Both are still one push away, just from here instead
            // of the rail.
            onOpenDemo: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => Scaffold(
                appBar: AppBar(
                  title: const Text('Demo'),
                  actions: const [HomeAppBarAction()],
                ),
                body: DemoScreen(onCompleted: _refreshWorkspaceViews),
              ),
            )),
            onOpenTelemetry: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const TaskScreen()),
            ),
          ),
        ),
        if (_showFor(_hr))
          ShellDestination(
          icon: Icons.people_outline,
          selectedIcon: Icons.people,
          label: 'Candidates',
          builder: (_) => CandidatesScreen(
            key: _candidatesKey,
            store: widget.store,
            candidateStore: widget.candidateStore,
            onStartSession: _goToInvitations,
          ),
        ),
        if (_showFor(_hr))
          ShellDestination(
          icon: Icons.work_outline,
          selectedIcon: Icons.work,
          label: 'Roles',
          builder: (_) => RolesScreen(
            key: _rolesKey,
            roleStore: widget.roleStore,
            intakeStore: widget.intakeStore,
            loadSessions: () => loadWorkspace(widget.store),
          ),
        ),
        if (_showFor(_hr))
          ShellDestination(
          icon: Icons.person_add_alt_1_outlined,
          selectedIcon: Icons.person_add_alt_1,
          label: 'Invitations',
          builder: (_) => InvitationsScreen(
            key: _invitationsKey,
            invitationStore: widget.invitationStore,
            roleStore: widget.roleStore,
            emailSender: widget.emailSender,
            senderName: widget.principal?.displayName,
            loadSessions: () => loadWorkspace(widget.store),
          ),
        ),
        if (_showFor(_hr))
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
        if (_showFor(_both))
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
            onStartSession: _goToInvitations,
          ),
        ),
        if (_showFor(_hr))
          ShellDestination(
          icon: Icons.forum_outlined,
          selectedIcon: Icons.forum,
          label: 'AI Interviews',
          builder: (_) => InterviewSessionsScreen(
            client: supabase.Supabase.instance.client,
          ),
        ),
        if (_showFor(_both))
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
            onDataChanged: _refreshWorkspaceViews,
            principal: widget.principal,
            // Raw sign-out, not `_confirmSignOut` — Settings' own Account
            // section already confirms before calling this, so chaining the
            // rail-footer's confirming wrapper here would ask twice.
            onSignOut: widget.onSignOut,
          ),
        ),
      ],
    );
  }
}
