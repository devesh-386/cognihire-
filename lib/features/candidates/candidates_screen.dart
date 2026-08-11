/// Candidates: stored sessions grouped by the label they were filed under.
///
/// ## What a "candidate" is in this app, stated plainly
///
/// It is a **label somebody typed**. There is no candidate record, no account, no
/// identity document, and no photograph. The verification path holds a face
/// embedding for the length of one session and discards it; nothing durable
/// identifies a person.
///
/// That is a real limitation and the UI says so rather than papering over it: two
/// spellings of one name are two candidates here. The alternative — fuzzy-matching
/// people's names into merged profiles — would invent an identity claim the app
/// cannot support, which is a worse failure than an obvious one.
///
/// ## Against the mockup
///
/// The design's candidate page led with a **"98% AI Match"** badge, a
/// **"Skill Score 95/100"**, an **"Interview: A+"** grade, and a
/// **"Behavioral 9.8"**. Those are four different composite scores over the same
/// unmeasured thing. They are replaced by counts of what the session recorded,
/// and the page keeps the mockup's shape: header, metric row, synthesis panel,
/// journey, and a right-hand column of per-skill detail.
///
/// The "Shortlist Candidate" button is also gone. This tool has no opinion about
/// who to hire and no state in which to record one; a shortlist button would be
/// the app taking exactly the step it exists to leave to a human.
library;

import 'package:flutter/material.dart';

import '../../core/candidates/candidate.dart';
import '../../core/candidates/candidate_store.dart';
import '../../core/claims/claim.dart';
import '../../core/claims/claim_audit.dart';
import '../../core/design/app_theme.dart';
import '../../core/export/audit_export.dart';
import '../../core/export/export_writer.dart';
import '../../core/persistence/audit_store.dart';
import '../../core/workspace/workspace_loader.dart';
import '../../core/workspace/workspace_stats.dart';
import '../../ui/app_shell.dart';
import '../../ui/components.dart';
import '../../ui/patterns.dart';
import '../audit/claim_audit_screen.dart';
import '../common/empty_state.dart';

class CandidatesScreen extends StatefulWidget {
  const CandidatesScreen({
    super.key,
    required this.store,
    this.candidateStore = const InMemoryCandidateStore(),
    this.onStartSession,
  });

  final AuditStore store;

  /// The real recruiting pipeline (organization -> role -> intake ->
  /// candidate), separate from [store]'s local session labels — see the
  /// library doc comment above for why the two are shown side by side
  /// rather than merged into one list.
  final CandidateStore candidateStore;

  final VoidCallback? onStartSession;

  @override
  State<CandidatesScreen> createState() => CandidatesScreenState();
}

class CandidatesScreenState extends State<CandidatesScreen> {
  WorkspaceSnapshot? _snapshot;
  List<Candidate>? _pipelineCandidates;
  String? _pipelineError;
  bool _loading = true;
  String _query = '';

  final _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    reload();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> reload() async {
    setState(() => _loading = true);
    final snapshot = await loadWorkspace(widget.store);
    List<Candidate>? pipelineCandidates;
    String? pipelineError;
    try {
      pipelineCandidates = await widget.candidateStore.listCandidates();
    } catch (error) {
      pipelineError = error.toString();
    }
    if (!mounted) return;
    setState(() {
      _snapshot = snapshot;
      _pipelineCandidates = pipelineCandidates;
      _pipelineError = pipelineError;
      _loading = false;
    });
  }

  /// Called by the app when the top-bar search is used, so one search field
  /// serves the whole shell rather than each screen growing its own.
  void applyQuery(String query) {
    setState(() {
      _query = query;
      _search.text = query;
    });
  }

  List<CandidateGroup> _visible(WorkspaceSnapshot snapshot) {
    final needle = _query.trim().toLowerCase();
    if (needle.isEmpty) return snapshot.candidates;

    return snapshot.candidates.where((group) {
      if (group.label.toLowerCase().contains(needle)) return true;
      // Searching claim text as well as the label: "who mentioned Postgres" is
      // the question a reviewer actually has, and the label cannot answer it.
      return group.sessions.any((session) => session.audit.findings.any((f) =>
          f.claim.text.toLowerCase().contains(needle) ||
          (f.claim.skill ?? '').toLowerCase().contains(needle)));
    }).toList();
  }

  void _openProfile(CandidateGroup group) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => CandidateProfileScreen(
        group: group,
        store: widget.store,
        onChanged: reload,
      ),
    ));
  }

  Widget _pipelineSection(BuildContext context) {
    final theme = Theme.of(context);
    final candidates = _pipelineCandidates;

    if (_loading && candidates == null && _pipelineError == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: Spacing.lg),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_pipelineError != null) {
      return InlineNotice(
        tone: NoticeTone.fault,
        message: 'Recruiting pipeline candidates could not be read: $_pipelineError',
      );
    }
    if (candidates == null || candidates.isEmpty) {
      return SectionCard(
        title: 'Recruiting pipeline',
        icon: Icons.route_outlined,
        description: 'Nobody has applied through an intake yet — see the '
            'Roles tab to create one and connect a Google Form.',
        child: const SizedBox.shrink(),
      );
    }

    final byIntake = <String, List<Candidate>>{};
    for (final c in candidates) {
      byIntake.putIfAbsent(c.intakeId ?? '', () => []).add(c);
    }

    return SectionCard(
      title: 'Recruiting pipeline',
      icon: Icons.route_outlined,
      description: '${candidates.length} candidate(s) who applied through an '
          'intake, grouped by campaign. Organization -> role -> intake -> '
          'candidate — established at application time, never guessed later.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final entry in byIntake.entries) ...[
            Text(
              entry.key.isEmpty
                  ? 'Unassigned (applied before intakes existed)'
                  : (entry.value.first.intakeName ?? entry.key),
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: Spacing.sm),
            for (final candidate in entry.value)
              Padding(
                padding: const EdgeInsets.only(bottom: Spacing.sm),
                child: _PipelineCandidateCard(candidate: candidate),
              ),
            const SizedBox(height: Spacing.md),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final snapshot = _snapshot;

    return ShellPage(
      title: 'Candidates',
      subtitle: 'Sessions grouped by the label they were filed under. That '
          'label is free text, so this grouping is an approximation and not an '
          'identity record.',
      actions: [
        IconButton(
          onPressed: _loading ? null : reload,
          tooltip: 'Refresh',
          icon: const Icon(Icons.refresh, size: 20),
        ),
      ],
      children: [
        _pipelineSection(context),
        const SizedBox(height: Spacing.section),
        Text('Local sessions', style: theme.textTheme.titleMedium),
        const SizedBox(height: Spacing.sm),
        Text(
          'Sessions run through this app directly, grouped by the free-text '
          'label they were filed under — not an identity record. See above '
          'for candidates who applied through the recruiting pipeline.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: Spacing.lg),
        SizedBox(
          height: 44,
          child: TextField(
            controller: _search,
            onChanged: (value) => setState(() => _query = value),
            decoration: InputDecoration(
              hintText: 'Filter by label, claim text, or skill tag',
              prefixIcon: const Icon(Icons.search, size: 18),
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Clear filter',
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () => setState(() {
                        _query = '';
                        _search.clear();
                      }),
                    ),
            ),
          ),
        ),
        const SizedBox(height: Spacing.xl),
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
        else if (snapshot.candidates.isEmpty)
          EmptyState(
            icon: Icons.people_outline,
            title: 'No candidates yet',
            body: 'A candidate appears here once a session has been saved '
                'under their label.',
            actionLabel:
                widget.onStartSession == null ? null : 'Start a session',
            onAction: widget.onStartSession,
          )
        else ...[
          if (_visible(snapshot).isEmpty)
            InlineNotice(
              message: 'No candidate matches "$_query". '
                  '${snapshot.candidates.length} are stored.',
            )
          else
            for (final group in _visible(snapshot))
              Padding(
                padding: const EdgeInsets.only(bottom: Spacing.md),
                child: _CandidateCard(
                  group: group,
                  onOpen: () => _openProfile(group),
                ),
              ),
          if (snapshot.unreadable.isNotEmpty) ...[
            const SizedBox(height: Spacing.xl),
            SectionCard(
              title: 'Sessions that could not be read',
              icon: Icons.error_outline,
              tone: SectionTone.fault,
              description: 'Listed rather than skipped. A record vanishing '
                  'silently would leave you believing you had seen everything.',
              child: Column(
                children: [
                  for (final bad in snapshot.unreadable)
                    KeyValueRow(
                      label: bad.id,
                      value: bad.problem,
                      monospaceValue: false,
                      tone: theme.colorScheme.error,
                    ),
                ],
              ),
            ),
          ],
        ],
      ],
    );
  }
}

class _CandidateCard extends StatelessWidget {
  const _CandidateCard({required this.group, required this.onOpen});

  final CandidateGroup group;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final latest = group.latest.audit;

    final skills = <String>{
      for (final session in group.sessions)
        for (final finding in session.audit.findings)
          if ((finding.claim.skill ?? '').trim().isNotEmpty)
            finding.claim.skill!.trim(),
    }.toList()
      ..sort();

    return Card(
      child: InkWell(
        onTap: onOpen,
        borderRadius: BorderRadius.circular(Radii.surface),
        child: Padding(
          padding: const EdgeInsets.all(Spacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Monogram(name: group.label, diameter: 46),
                  const SizedBox(width: Spacing.lg),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(group.label, style: theme.textTheme.titleLarge),
                        const SizedBox(height: 2),
                        Text(
                          '${group.sessions.length} session'
                          '${group.sessions.length == 1 ? '' : 's'} · '
                          '${group.claimCount} claim'
                          '${group.claimCount == 1 ? '' : 's'} · last '
                          '${_date(group.lastSeen)}',
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: Spacing.sm),
                  provenanceTag(context, latest.provenanceQuality),
                ],
              ),
              const SizedBox(height: Spacing.lg),
              Text(latest.summary, style: theme.textTheme.bodyMedium),
              if (skills.isNotEmpty) ...[
                const SizedBox(height: Spacing.lg),
                Wrap(
                  spacing: Spacing.sm,
                  runSpacing: Spacing.sm,
                  children: [
                    for (final skill in skills.take(8)) Tag(label: skill),
                    if (skills.length > 8)
                      Tag(label: '+${skills.length - 8} more'),
                  ],
                ),
              ],
            ],
          ),
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

class _PipelineCandidateCard extends StatelessWidget {
  const _PipelineCandidateCard({required this.candidate});

  final Candidate candidate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Spacing.lg),
        child: Row(
          children: [
            Monogram(name: candidate.name, diameter: 40),
            const SizedBox(width: Spacing.lg),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(candidate.name, style: theme.textTheme.titleMedium),
                  Text(
                    '${candidate.email}'
                    '${candidate.roleTitle == null ? '' : ' · ${candidate.roleTitle}'}',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            if (candidate.processingStatus != null)
              Tag(label: candidate.processingStatus!.toLowerCase().replaceAll('_', ' ')),
          ],
        ),
      ),
    );
  }
}

/// A pill stating the session's provenance quality.
///
/// Four states, each its own colour, and "sparse" is deliberately not a paler
/// version of "solid" — incomplete coverage must not read as nearly-verified.
Widget provenanceTag(BuildContext context, ProvenanceQuality quality) {
  final evidence = context.evidence;
  final (String label, Color colour, IconData icon) = switch (quality) {
    ProvenanceQuality.solid => (
        'Identity verified',
        evidence.verified,
        Icons.verified_user_outlined,
      ),
    ProvenanceQuality.disputed => (
        'Identity disputed',
        evidence.disputed,
        Icons.report_gmailerrorred_outlined,
      ),
    ProvenanceQuality.sparse => (
        'Coverage incomplete',
        evidence.unmeasured,
        Icons.visibility_off_outlined,
      ),
    ProvenanceQuality.none => (
        'Not verified',
        evidence.notExamined,
        Icons.help_outline,
      ),
  };

  return Tag(label: label, tone: colour, icon: icon);
}

// ---------------------------------------------------------------------------
// Profile
// ---------------------------------------------------------------------------

class CandidateProfileScreen extends StatefulWidget {
  const CandidateProfileScreen({
    super.key,
    required this.group,
    required this.store,
    this.onChanged,
  });

  final CandidateGroup group;
  final AuditStore store;

  /// Called after a mutation (a session deleted), so the list behind this screen
  /// does not keep showing a record that is gone.
  final VoidCallback? onChanged;

  @override
  State<CandidateProfileScreen> createState() => _CandidateProfileScreenState();
}

class _CandidateProfileScreenState extends State<CandidateProfileScreen> {
  late SessionRecord _selected = widget.group.latest;
  bool _exporting = false;

  ClaimAudit get _audit => _selected.audit;

  Future<void> _export() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _exporting = true);

    try {
      final html = renderAuditHtml(
        _audit,
        label: _selected.label,
        generatedAt: DateTime.now(),
      );
      final safe = _selected.label
          .replaceAll(RegExp(r'[^A-Za-z0-9]+'), '-')
          .replaceAll(RegExp(r'^-+|-+$'), '');
      final stamp = _audit.sessionEnd
          .toIso8601String()
          .substring(0, 19)
          .replaceAll(RegExp('[:-]'), '');
      final path = await writeAuditExport(
        html,
        filename: 'cognihire-${safe.isEmpty ? 'session' : safe}-$stamp.html',
      );
      messenger.showSnackBar(SnackBar(
        duration: const Duration(seconds: 8),
        content: Text('Audit written to $path'),
      ));
    } catch (error) {
      messenger.showSnackBar(SnackBar(
        duration: const Duration(seconds: 8),
        content: Text('Export failed: $error'),
      ));
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this session?'),
        content: Text(
          'The stored audit for "${_selected.label}" recorded '
          '${_audit.sessionEnd.difference(_audit.sessionStart).inMinutes} '
          'minutes and ${_audit.findings.length} claim(s). Deleting it removes '
          'the evidence trail permanently; there is no undo and no copy '
          'elsewhere.',
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

    if (confirmed != true || !mounted) return;

    await widget.store.deleteAudit(_selected.id);
    widget.onChanged?.call();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.group.label),
        actions: [
          if (widget.group.sessions.length > 1)
            PopupMenuButton<String>(
              tooltip: 'Choose which session to view',
              position: PopupMenuPosition.under,
              icon: const Icon(Icons.layers_outlined, size: 20),
              onSelected: (id) => setState(() {
                _selected = widget.group.sessions
                    .firstWhere((session) => session.id == id);
              }),
              itemBuilder: (context) => [
                for (final session in widget.group.sessions)
                  PopupMenuItem<String>(
                    value: session.id,
                    child: Text(
                      '${_stamp(session.audit.sessionEnd)} — '
                      '${session.audit.findings.length} claim(s)'
                      '${session.id == _selected.id ? '  ·  showing' : ''}',
                    ),
                  ),
              ],
            ),
          IconButton(
            onPressed: _exporting ? null : _export,
            tooltip: 'Export this session as HTML',
            icon: _exporting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.download_outlined, size: 20),
          ),
          IconButton(
            onPressed: _delete,
            tooltip: 'Delete this session',
            icon: const Icon(Icons.delete_outline, size: 20),
          ),
          const SizedBox(width: Spacing.sm),
        ],
      ),
      body: ShellPage(
        title: widget.group.label,
        subtitle: 'Session of ${_stamp(_audit.sessionEnd)}'
            '${widget.group.sessions.length > 1 ? ' — one of '
                '${widget.group.sessions.length} filed under this label' : ''}',
        actions: [
          OutlinedButton.icon(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => ClaimAuditScreen(
                audit: _audit,
                label: _selected.label,
              ),
            )),
            icon: const Icon(Icons.fact_check_outlined, size: 18),
            label: const Text('Full claim audit'),
          ),
        ],
        children: _body(context),
      ),
    );
  }

  List<Widget> _body(BuildContext context) {
    final theme = Theme.of(context);
    final evidence = context.evidence;
    final audit = _audit;

    final substantiated = audit.byStatus(ClaimStatus.substantiated);
    final notDemonstrated = audit.byStatus(ClaimStatus.notDemonstrated);
    final contradicted = audit.byStatus(ClaimStatus.contradicted);
    final notExamined = audit.byStatus(ClaimStatus.notExamined);

    final evidenceCount =
        audit.findings.fold(0, (sum, f) => sum + f.evidence.length);

    final stats = WorkspaceStats.from([_selected]);

    return [
      _header(context),
      const SizedBox(height: Spacing.xl),

      MetricStrip(
        children: [
          MetricCard(
            label: 'Claims',
            value: '${audit.findings.length}',
            icon: Icons.list_alt_outlined,
            qualifier: 'Confirmed by the candidate from their own resume',
          ),
          MetricCard(
            label: 'Examined',
            value: '${audit.findings.length - notExamined.length}',
            unit: '/${audit.findings.length}',
            icon: Icons.search,
            emphasised: true,
            fraction: audit.findings.isEmpty
                ? null
                : (audit.findings.length - notExamined.length) /
                    audit.findings.length,
            qualifier: '${notExamined.length} never tested',
          ),
          MetricCard(
            label: 'Substantiated',
            value: '${substantiated.length}',
            icon: Icons.check_circle_outline,
            tone: evidence.verified,
            qualifier: 'A reviewer judged these demonstrated',
          ),
          MetricCard(
            label: 'Not demonstrated',
            value: '${notDemonstrated.length}',
            icon: Icons.remove_circle_outline,
            tone: evidence.unmeasured,
            qualifier: 'Probed; the response did not show it. Not an '
                'accusation — people freeze and misremember',
          ),
          MetricCard(
            label: 'Evidence items',
            value: '$evidenceCount',
            icon: Icons.description_outlined,
            qualifier: 'Recorded observations behind the claims above',
          ),
          MetricCard(
            label: 'Duration',
            value: '${audit.sessionEnd.difference(audit.sessionStart).inMinutes}',
            unit: 'min',
            icon: Icons.timer_outlined,
            qualifier: 'From session start to session end',
          ),
        ],
      ),
      const SizedBox(height: Spacing.section),

      LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 920;
          final left = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _synthesis(context, substantiated, notDemonstrated,
                  contradicted, notExamined),
              const SizedBox(height: Spacing.xl),
              _journey(context),
            ],
          );
          final right = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _skillPanel(context, stats),
              const SizedBox(height: Spacing.xl),
              _provenancePanel(context),
              const SizedBox(height: Spacing.xl),
              _recordPanel(context),
            ],
          );

          if (!wide) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [left, const SizedBox(height: Spacing.xl), right],
            );
          }

          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 3, child: left),
              const SizedBox(width: Spacing.xl),
              Expanded(flex: 2, child: right),
            ],
          );
        },
      ),

      const SizedBox(height: Spacing.section),
      Text(
        'This record states what was observed. It contains no rating, no '
        'ranking, and no hiring recommendation — those remain entirely with '
        'you.',
        textAlign: TextAlign.center,
        style: theme.textTheme.bodySmall,
      ),
    ];
  }

  Widget _header(BuildContext context) {
    final theme = Theme.of(context);
    final audit = _audit;

    final skills = <String>{
      for (final finding in audit.findings)
        if ((finding.claim.skill ?? '').trim().isNotEmpty)
          finding.claim.skill!.trim(),
    }.toList()
      ..sort();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Spacing.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Wrap rather than Row: the header carries a monogram, a long label,
            // and a provenance pill, and on a narrow window those need to fold.
            Wrap(
              spacing: Spacing.lg,
              runSpacing: Spacing.lg,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Monogram(name: widget.group.label, diameter: 64),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        widget.group.label,
                        style: theme.textTheme.displaySmall,
                      ),
                      const SizedBox(height: Spacing.xs),
                      Text(audit.summary, style: theme.textTheme.bodyMedium),
                    ],
                  ),
                ),
                provenanceTag(context, audit.provenanceQuality),
              ],
            ),
            if (skills.isNotEmpty) ...[
              const SizedBox(height: Spacing.lg),
              Wrap(
                spacing: Spacing.sm,
                runSpacing: Spacing.sm,
                children: [for (final skill in skills) Tag(label: skill)],
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// The mockup's "AI Synthesis Recommendation", rebuilt as a synthesis that
  /// recommends nothing: two lists of claims, quoted, with what was seen and
  /// what was not.
  Widget _synthesis(
    BuildContext context,
    List<ClaimFinding> substantiated,
    List<ClaimFinding> notDemonstrated,
    List<ClaimFinding> contradicted,
    List<ClaimFinding> notExamined,
  ) {
    final theme = Theme.of(context);
    final evidence = context.evidence;

    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.surface),
        // The mockup gave this card a gold top border to mark it as the
        // generated one. Kept, because knowing which panel was assembled by the
        // system rather than typed by a human is genuinely useful.
        side: BorderSide(color: context.brand.accent.withValues(alpha: 0.6)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(Spacing.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'SESSION SYNTHESIS',
                    style: theme.textTheme.labelSmall,
                  ),
                ),
                Icon(
                  Icons.auto_awesome_outlined,
                  size: 16,
                  color: context.brand.accent,
                ),
              ],
            ),
            const SizedBox(height: Spacing.md),
            Text(
              'Assembled from this session\'s record by the rules in '
              '`ClaimAuditBuilder`. It restates what happened and draws no '
              'conclusion about the candidate.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: Spacing.lg),
            Text(_audit.summary, style: theme.textTheme.bodyLarge),
            const SizedBox(height: Spacing.xl),
            ResponsiveColumns(
              minColumnWidth: 240,
              children: [
                _claimList(
                  context,
                  heading: 'Shown under questioning',
                  colour: evidence.verified,
                  findings: substantiated,
                  emptyNote: 'No claim was marked substantiated in this '
                      'session.',
                ),
                _claimList(
                  context,
                  heading: 'Not shown',
                  colour: evidence.unmeasured,
                  findings: [...notDemonstrated, ...contradicted],
                  emptyNote: 'Every examined claim was substantiated.',
                ),
              ],
            ),
            if (notExamined.isNotEmpty) ...[
              const SizedBox(height: Spacing.lg),
              InlineNotice(
                tone: NoticeTone.caution,
                message: '${notExamined.length} claim(s) were never examined. '
                    'That is silence, not a pass and not a fail — nothing in '
                    'this session tested them.',
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _claimList(
    BuildContext context, {
    required String heading,
    required Color colour,
    required List<ClaimFinding> findings,
    required String emptyNote,
  }) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(Spacing.lg),
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(Radii.control),
        border: Border.all(color: colour.withValues(alpha: 0.22)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            heading.toUpperCase(),
            style: theme.textTheme.labelSmall?.copyWith(color: colour),
          ),
          const SizedBox(height: Spacing.md),
          if (findings.isEmpty)
            Text(emptyNote, style: theme.textTheme.bodySmall)
          else
            for (final finding in findings)
              Padding(
                padding: const EdgeInsets.only(bottom: Spacing.sm),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 5, right: Spacing.sm),
                      child: Container(
                        width: 5,
                        height: 5,
                        decoration: BoxDecoration(
                          color: colour,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            finding.claim.text,
                            style: theme.textTheme.bodyMedium,
                          ),
                          Text(
                            '${finding.status.label} · '
                            '${finding.evidence.length} evidence item(s) · '
                            '${finding.claim.source}',
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }

  /// The mockup's "Professional Journey" — a career timeline it had no data for.
  /// This is the session's own timeline instead: the evidence, in the order it
  /// was actually recorded.
  Widget _journey(BuildContext context) {
    final theme = Theme.of(context);

    final entries = <({DateTime at, ClaimFinding finding, ClaimEvidence item})>[
      for (final finding in _audit.findings)
        for (final item in finding.evidence)
          (at: item.at, finding: finding, item: item),
    ]..sort((a, b) => a.at.compareTo(b.at));

    return SectionCard(
      title: 'Session timeline',
      icon: Icons.timeline_outlined,
      description: 'Every recorded observation, in the order it happened. This '
          'is the session, not a career history — the app has no data about '
          'anyone\'s past employment.',
      child: entries.isEmpty
          ? Text(
              'No evidence was recorded during this session, so there is no '
              'timeline. Every claim is reported as not examined.',
              style: theme.textTheme.bodySmall,
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < entries.length; i++)
                  TimelineEntry(
                    isLast: i == entries.length - 1,
                    tone: switch (entries[i].item.kind) {
                      EvidenceKind.probeResponse => context.brand.accent,
                      EvidenceKind.processSignal =>
                        theme.colorScheme.secondary,
                      EvidenceKind.identityCheck =>
                        context.evidence.verified,
                    },
                    title: switch (entries[i].item.kind) {
                      EvidenceKind.probeResponse => 'Probe and response',
                      EvidenceKind.processSignal => 'Process signal',
                      EvidenceKind.identityCheck => 'Identity check',
                    },
                    meta: _clock(entries[i].at),
                    body: '${entries[i].item.observation}\n'
                        '— on: "${entries[i].finding.claim.text}"',
                  ),
              ],
            ),
    );
  }

  Widget _skillPanel(BuildContext context, WorkspaceStats stats) {
    final theme = Theme.of(context);

    if (stats.skills.isEmpty) {
      return SectionCard(
        title: 'Coverage by skill',
        icon: Icons.hub_outlined,
        child: Text(
          'None of this session\'s claims carry a skill tag, so there is '
          'nothing to break down.',
          style: theme.textTheme.bodySmall,
        ),
      );
    }

    return SectionCard(
      title: 'Coverage by skill',
      icon: Icons.hub_outlined,
      description: 'Claims for each tag, and how many were examined. A level '
          'like "Advanced" is not shown because nothing here measures one.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          RadarChart(
            size: 190,
            axes: [
              for (final skill in stats.skills.take(7))
                RadarAxis(
                  label: skill.skill,
                  fraction: skill.examinedFraction ?? 0,
                  detail: '${skill.examined}/${skill.claims} examined',
                ),
            ],
          ),
          const SizedBox(height: Spacing.xl),
          for (final skill in stats.skills)
            SkillMeter(
              skill: skill.skill,
              level: '${skill.substantiated} of ${skill.claims} substantiated',
              fraction:
                  skill.claims == 0 ? 0 : skill.substantiated / skill.claims,
            ),
        ],
      ),
    );
  }

  Widget _provenancePanel(BuildContext context) {
    final audit = _audit;

    return SectionCard(
      title: 'Identity provenance',
      icon: Icons.shield_outlined,
      description: 'Whether the same person was in front of the camera '
          'throughout, and how often that could be checked.',
      child: Column(
        children: [
          Center(
            child: RingGauge(
              diameter: 118,
              fraction: audit.identityCoverage,
              caption: 'measured',
              unavailableNote: 'no checks',
            ),
          ),
          const SizedBox(height: Spacing.lg),
          KeyValueRow(
            label: 'Attempts',
            value: '${audit.identityAttempts.length}',
          ),
          KeyValueRow(
            label: 'Measured',
            value: '${audit.identityChecksPerformed}',
          ),
          KeyValueRow(
            label: 'Matched',
            value: '${audit.identityChecksVerified}',
            tone: context.evidence.verified,
          ),
          const SizedBox(height: Spacing.md),
          Align(
            alignment: Alignment.centerLeft,
            child: provenanceTag(context, audit.provenanceQuality),
          ),
        ],
      ),
    );
  }

  Widget _recordPanel(BuildContext context) {
    final audit = _audit;

    return SectionCard(
      title: 'The record itself',
      icon: Icons.folder_outlined,
      description: 'Where this came from, so it can be checked.',
      child: Column(
        children: [
          KeyValueRow(label: 'Session id', value: _selected.id),
          KeyValueRow(label: 'Started', value: _clock(audit.sessionStart)),
          KeyValueRow(label: 'Ended', value: _clock(audit.sessionEnd)),
          KeyValueRow(
            label: 'Event log',
            value: audit.sessionEventsJsonl.isEmpty
                ? 'none recorded'
                : '${audit.sessionEventsJsonl.trim().split('\n').length} '
                    'hash-chained entries',
            monospaceValue: audit.sessionEventsJsonl.isNotEmpty,
          ),
          const SizedBox(height: Spacing.md),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _exporting ? null : _export,
              icon: const Icon(Icons.download_outlined, size: 18),
              label: const Text('Export full audit as HTML'),
            ),
          ),
        ],
      ),
    );
  }

  static String _stamp(DateTime time) {
    final l = time.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)} '
        '${two(l.hour)}:${two(l.minute)}';
  }

  static String _clock(DateTime time) {
    final l = time.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)} '
        '${two(l.hour)}:${two(l.minute)}:${two(l.second)}';
  }
}
