/// The workspace overview — the Golden Taupe dashboard, with real arithmetic.
///
/// ## Where the numbers come from
///
/// Every figure on this screen is computed by [WorkspaceStats] from stored
/// audits, and every one of them is a count or a ratio of two counts that are
/// both printed next to it. Nothing is sampled, estimated, or projected.
///
/// ## What the mockup had here that this does not
///
/// The design put five things on this page that are gone:
///
/// * a **"Hiring Score 88/100"** card, and
/// * an **"AI Accuracy 99.4%"** card — both aggregate scores with nothing
///   behind them. This product's whole argument is that a composite number
///   destroys the information a reviewer needs; putting two of them on the front
///   page would end that argument.
/// * a **"Shortlisted 156"** counter. There is no shortlist: the app records
///   evidence and the human decides, so there is no state for it to count.
/// * an **"AI Optimization Tip"** panel advising the reader to accelerate an
///   interview phase. That is a recommendation about a hiring decision, which is
///   the one output this tool refuses to produce.
/// * a **calendar sync** button. Nothing here talks to a calendar, so the
///   affordance became "open the most recent session", which is what a reviewer
///   actually wants from that corner of the screen.
///
/// What replaced them are figures the app can defend: how many claims were
/// examined out of how many were ingested, how much of the identity checking
/// actually measured something, and how much evidence exists per skill.
library;

import 'package:flutter/material.dart';

import '../../core/claims/claim.dart';
import '../../core/design/app_theme.dart';
import '../../core/persistence/audit_store.dart';
import '../../core/workspace/workspace_loader.dart';
import '../../core/workspace/workspace_stats.dart';
import '../../ui/app_shell.dart';
import '../../ui/components.dart';
import '../../ui/patterns.dart';
import '../../ui/tokens.dart';
import '../audit/claim_audit_screen.dart';
import '../common/empty_state.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({
    super.key,
    required this.store,
    required this.storageLocation,
    required this.storageIsDurable,
    this.onStartSession,
  });

  final AuditStore store;
  final String storageLocation;
  final bool storageIsDurable;

  /// Where the "run a session" affordances go. Provided by the app rather than
  /// hardcoded so this screen does not need to know how navigation works.
  final VoidCallback? onStartSession;

  @override
  State<DashboardScreen> createState() => DashboardScreenState();
}

class DashboardScreenState extends State<DashboardScreen> {
  WorkspaceSnapshot? _snapshot;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    reload();
  }

  /// Public so the app can refresh the dashboard when a session finishes, rather
  /// than the user having to notice it is stale and press the button.
  Future<void> reload() async {
    setState(() => _loading = true);
    final snapshot = await loadWorkspace(widget.store);
    if (!mounted) return;
    setState(() {
      _snapshot = snapshot;
      _loading = false;
    });
  }

  void _open(SessionRecord record) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ClaimAuditScreen(
        audit: record.audit,
        label: record.label,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final snapshot = _snapshot;

    return ShellPage(
      title: _greeting(),
      subtitle: 'Every figure here is a count of something recorded in a '
          'session. There is no overall score, because this tool does not '
          'produce one.',
      actions: [
        Text(
          _today(),
          style: context.numeric.copyWith(
            color: theme.textTheme.bodySmall?.color,
          ),
        ),
        const SizedBox(width: Spacing.sm),
        IconButton(
          onPressed: _loading ? null : reload,
          tooltip: 'Refresh',
          icon: const Icon(Icons.refresh, size: 20),
        ),
      ],
      children: [
        if (_loading && snapshot == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: Spacing.hero),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (snapshot == null)
          const InlineNotice(
            tone: NoticeTone.fault,
            message: 'The session store could not be read.',
          )
        else ...[
          if (snapshot.storeError != null) ...[
            InlineNotice(
              tone: NoticeTone.fault,
              icon: Icons.error_outline,
              message: 'Sessions could not be listed: '
                  '${snapshot.storeError}. The figures below are therefore '
                  'not a count of your work — they are a count of nothing.',
            ),
            const SizedBox(height: Spacing.xl),
          ],
          if (!widget.storageIsDurable) ...[
            InlineNotice(
              tone: NoticeTone.caution,
              icon: Icons.warning_amber,
              message: 'Storage is not durable on this platform '
                  '(${widget.storageLocation}). Sessions will not survive '
                  'closing the app.',
            ),
            const SizedBox(height: Spacing.xl),
          ],
          if (snapshot.stats.isEmpty)
            EmptyState(
              icon: Icons.insights_outlined,
              title: 'No sessions recorded yet',
              body: 'The dashboard reports on completed sessions. Run one and '
                  'every figure here fills in from what was actually observed.',
              actionLabel:
                  widget.onStartSession == null ? null : 'Start a session',
              onAction: widget.onStartSession,
            )
          else
            ..._populated(context, snapshot),
        ],
      ],
    );
  }

  List<Widget> _populated(BuildContext context, WorkspaceSnapshot snapshot) {
    final stats = snapshot.stats;
    final theme = Theme.of(context);
    final evidence = context.evidence;

    return [
      MetricStrip(
        children: [
          MetricCard(
            label: 'Sessions',
            value: '${stats.sessions}',
            icon: Icons.event_note_outlined,
            qualifier: stats.unreadableSessions == 0
                ? 'Completed and saved'
                : '${stats.unreadableSessions} more could not be read',
            tone: stats.unreadableSessions == 0 ? null : theme.colorScheme.error,
          ),
          MetricCard(
            label: 'Candidate labels',
            value: '${stats.candidates}',
            icon: Icons.badge_outlined,
            qualifier: 'Distinct labels typed by the operator — an '
                'approximation, not an identity record',
          ),
          MetricCard(
            label: 'Claims examined',
            value: '${stats.claimsExamined}',
            unit: '/${stats.claimsTotal}',
            icon: Icons.fact_check_outlined,
            emphasised: true,
            fraction: stats.examinedFraction,
            qualifier:
                '${stats.statusCount(ClaimStatus.notExamined)} were never '
                'tested and are reported as such',
          ),
          MetricCard(
            label: 'Substantiated',
            value: '${stats.statusCount(ClaimStatus.substantiated)}',
            icon: Icons.verified_outlined,
            tone: evidence.verified,
            qualifier: 'A reviewer marked these demonstrated. '
                '${stats.statusCount(ClaimStatus.notDemonstrated)} probed but '
                'not demonstrated',
          ),
          MetricCard(
            label: 'Evidence items',
            value: '${stats.evidenceItems}',
            icon: Icons.description_outlined,
            qualifier: 'Individual recorded observations across all claims',
          ),
          // The one figure the mockup's "AI Accuracy" card should always have
          // been: not how good the system is, but how often it managed to look.
          stats.identityAttempts == 0
              ? const MetricCard.unavailable(
                  label: 'Identity coverage',
                  reason: 'No identity check was attempted in any stored '
                      'session, so there is no coverage to report.',
                  icon: Icons.shield_outlined,
                )
              : MetricCard(
                  label: 'Identity coverage',
                  value: '${((stats.identityCoverage ?? 0) * 100).round()}',
                  unit: '%',
                  icon: Icons.shield_outlined,
                  fraction: stats.identityCoverage,
                  qualifier: '${stats.identityMeasured} of '
                      '${stats.identityAttempts} attempts measured something; '
                      '${stats.identityVerified} of those matched',
                ),
        ],
      ),
      const SizedBox(height: Spacing.section),

      // Funnel and the side column. Two columns on a wide window, stacked
      // below — specified, not accidental.
      LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 900;
          final funnel = _funnelCard(context, stats);
          final side = _sideColumn(context, snapshot);

          if (!wide) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                funnel,
                const SizedBox(height: Spacing.xl),
                side,
              ],
            );
          }

          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 3, child: funnel),
              const SizedBox(width: Spacing.xl),
              Expanded(flex: 2, child: side),
            ],
          );
        },
      ),

      const SizedBox(height: Spacing.section),
      _skillsCard(context, stats),
      const SizedBox(height: Spacing.section),
      _activityCard(context, snapshot),
    ];
  }

  Widget _funnelCard(BuildContext context, WorkspaceStats stats) {
    final theme = Theme.of(context);

    return SectionCard(
      title: 'Claim provenance funnel',
      icon: Icons.filter_alt_outlined,
      description: 'How far each claim got. Every stage is a strict subset of '
          'the one above it, so the counts can only fall.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FunnelChart(
            stages: [
              for (final stage in stats.funnel)
                FunnelStage(
                  label: stage.label,
                  count: stage.count,
                  explanation: stage.definition,
                ),
            ],
          ),
          const SizedBox(height: Spacing.xl),
          Text(
            'Hover any bar to read the exact predicate it counts. The drop '
            'between "probed" and "ruled on" is the reviewer\'s remaining work, '
            'not a defect in the candidate.',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _sideColumn(BuildContext context, WorkspaceSnapshot snapshot) {
    final stats = snapshot.stats;
    final recent = snapshot.records.take(4).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionCard(
          title: 'Identity checking',
          icon: Icons.shield_outlined,
          description: 'Across every stored session.',
          child: Column(
            children: [
              Center(
                child: RingGauge(
                  fraction: stats.identityVerifiedFraction,
                  caption: 'matched',
                  centreLabel: stats.identityMeasured == 0
                      ? null
                      : '${stats.identityVerified}',
                  unavailableNote: 'nothing\nmeasured',
                ),
              ),
              const SizedBox(height: Spacing.lg),
              KeyValueRow(
                label: 'Attempts',
                value: '${stats.identityAttempts}',
              ),
              KeyValueRow(
                label: 'Actually measured',
                value: '${stats.identityMeasured}',
              ),
              KeyValueRow(
                label: 'Matched the reference',
                value: '${stats.identityVerified}',
                tone: context.evidence.verified,
              ),
              KeyValueRow(
                label: 'Could not be performed',
                value:
                    '${stats.identityAttempts - stats.identityMeasured}',
                tone: context.evidence.unmeasured,
              ),
            ],
          ),
        ),
        const SizedBox(height: Spacing.xl),
        SectionCard(
          title: 'Most recent sessions',
          icon: Icons.schedule_outlined,
          trailing: recent.isEmpty
              ? null
              : TextButton(
                  onPressed: () =>
                      AppShellController.of(context)?.goTo('Sessions'),
                  child: const Text('See all'),
                ),
          child: recent.isEmpty
              ? Text(
                  'Nothing saved yet.',
                  style: Theme.of(context).textTheme.bodySmall,
                )
              : Column(
                  children: [
                    for (final record in recent)
                      RecordRow(
                        leading: Monogram(name: record.label, diameter: 34),
                        title: record.label,
                        subtitle: record.audit.summary,
                        trailing: const Icon(Icons.chevron_right, size: 18),
                        onTap: () => _open(record),
                      ),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _skillsCard(BuildContext context, WorkspaceStats stats) {
    final theme = Theme.of(context);

    if (stats.skills.isEmpty) {
      return SectionCard(
        title: 'Evidence by skill',
        icon: Icons.hub_outlined,
        child: Text(
          'None of the claims in these sessions carry a skill tag, so there is '
          'nothing to break down. Tags come from the resume reader and are '
          'optional — an untagged claim is still examined, it just cannot be '
          'grouped here.',
          style: theme.textTheme.bodySmall,
        ),
      );
    }

    // Radar for shape, table for fact. Neither alone is sufficient: the polygon
    // is quick to read and easy to misjudge, the numbers are precise and slow.
    final axes = [
      for (final skill in stats.skills.take(7))
        RadarAxis(
          label: skill.skill,
          fraction: skill.examinedFraction ?? 0,
          detail: '${skill.examined} of ${skill.claims} examined',
        ),
    ];

    return SectionCard(
      title: 'Evidence by skill',
      icon: Icons.hub_outlined,
      description: 'Claims grouped by their skill tag. The plot shows the share '
          'of each skill\'s claims that were examined at all.',
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 720;

          final meters = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final skill in stats.skills.take(7))
                SkillMeter(
                  skill: skill.skill,
                  // A count, not a grade. The mockup put "Advanced" and
                  // "Proficient" here; nothing in this app can support that.
                  level: '${skill.substantiated} substantiated of '
                      '${skill.claims}',
                  fraction: skill.claims == 0
                      ? 0
                      : skill.substantiated / skill.claims,
                ),
              if (stats.skills.length > 7)
                Text(
                  '${stats.skills.length - 7} further skill tag(s) not shown.',
                  style: theme.textTheme.bodySmall,
                ),
            ],
          );

          if (!wide) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                meters,
                const SizedBox(height: Spacing.xl),
                RadarChart(axes: axes),
              ],
            );
          }

          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: meters),
              const SizedBox(width: Spacing.xxl),
              SizedBox(width: 260, child: RadarChart(axes: axes)),
            ],
          );
        },
      ),
    );
  }

  Widget _activityCard(BuildContext context, WorkspaceSnapshot snapshot) {
    final items = snapshot.stats.activity.take(8).toList();

    return SectionCard(
      title: 'Recent activity',
      icon: Icons.history,
      description: 'Sessions as they were saved, newest first. Faults are '
          'listed alongside successes rather than hidden.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < items.length; i++)
            TimelineEntry(
              isLast: i == items.length - 1,
              tone: items[i].isFault ? context.evidence.disputed : null,
              title: items[i].title,
              meta: items[i].isFault ? 'unreadable' : _stamp(items[i].at),
              body: items[i].detail,
            ),
        ],
      ),
    );
  }

  /// Time-of-day greeting from the actual clock. Trivial, and the mockup's
  /// hardcoded "Good morning" would have been wrong two-thirds of the day.
  String _greeting() {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'Good morning';
    if (hour < 18) return 'Good afternoon';
    return 'Good evening';
  }

  static String _today() {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final now = DateTime.now();
    return '${months[now.month - 1]} ${now.day}, ${now.year}';
  }

  static String _stamp(DateTime time) {
    final local = time.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }
}
