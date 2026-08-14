/// AI Interviews — read-only review of sessions the backend conducted via
/// the candidate portal.
///
/// ## How this differs from "Sessions" / "Candidates"
///
/// Those screens are the *local* audit trail: sessions run on this device,
/// stored in [AuditStore], with faces and probe/response evidence. This
/// screen reads a different thing entirely — sessions the FastAPI gateway
/// (`service/session/interview_session.py`) ran against a candidate on the
/// portal, stored in Supabase's `interview_sessions` / `interview_events`.
/// Nothing here is merged with the local audit model; they are two
/// independent interview mechanisms this app currently supports, and
/// conflating them would misrepresent which one produced which evidence.
///
/// Same restraint as the rest of the app applies: no score, no ranking, no
/// recommendation — a status, a coverage percentage (a count of topics
/// attempted out of topics planned, not a judgement), and the transcript.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

import '../../core/candidates/candidate_resume_client.dart';
import '../../core/design/app_theme.dart';
import '../../core/export/export_writer.dart';
import '../../core/interview_sessions/email_status_client.dart';
import '../../core/interview_sessions/interview_code_client.dart';
import '../../core/interview_sessions/interview_report_client.dart';
import '../../core/interview_sessions/interview_session_models.dart';
import '../../core/interview_sessions/interview_session_store.dart';
import '../../ui/app_shell.dart';
import '../../ui/components.dart';
import '../../ui/patterns.dart';
import '../common/empty_state.dart';

class InterviewSessionsScreen extends StatefulWidget {
  const InterviewSessionsScreen({super.key, required this.client});

  final supabase.SupabaseClient client;

  @override
  State<InterviewSessionsScreen> createState() =>
      InterviewSessionsScreenState();
}

class InterviewSessionsScreenState extends State<InterviewSessionsScreen> {
  late final _store = SupabaseInterviewSessionStore(widget.client);
  final _codeClient = InterviewCodeClient();
  InterviewSessionListResult? _result;
  bool _loading = true;

  String? get _organizationId => widget.client.auth.currentUser?.userMetadata?[
      'organization_id'] as String?;

  @override
  void initState() {
    super.initState();
    reload();
  }

  Future<void> reload() async {
    setState(() => _loading = true);
    final result = await _store.listSessions();
    if (!mounted) return;
    setState(() {
      _result = result;
      _loading = false;
    });
  }

  void _open(InterviewSessionSummary session) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => InterviewSessionDetailScreen(
        store: _store,
        session: session,
      ),
    ));
  }

  Future<void> _generateCode() async {
    final organizationId = _organizationId;
    if (organizationId == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('No organization on this account — cannot generate a code.'),
      ));
      return;
    }

    final request = await showDialog<({String candidateId, String roleTitle})>(
      context: context,
      builder: (_) => const _GenerateCodeDialog(),
    );
    if (request == null || !mounted) return;

    try {
      final generated = await _codeClient.generate(
        candidateId: request.candidateId,
        organizationId: organizationId,
        roleTitle: request.roleTitle,
      );
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => _GeneratedCodeDialog(generated: generated),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Could not generate a code: $error'),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;

    return ShellPage(
      title: 'AI Interviews',
      subtitle: 'Sessions the backend conducted through the candidate '
          'portal. Coverage is a count of topics attempted out of topics '
          'planned — not a score.',
      actions: [
        OutlinedButton.icon(
          onPressed: _generateCode,
          icon: const Icon(Icons.qr_code_2_outlined, size: 18),
          label: const Text('Generate code'),
        ),
        const SizedBox(width: Spacing.sm),
        IconButton(
          onPressed: _loading ? null : reload,
          tooltip: 'Refresh',
          icon: const Icon(Icons.refresh, size: 20),
        ),
      ],
      children: [
        if (_loading && result == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: Spacing.hero),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (result == null)
          const InlineNotice(
            tone: NoticeTone.fault,
            message: 'Interview sessions could not be read.',
          )
        else ...[
          if (result.problem != null)
            InlineNotice(
              tone: NoticeTone.fault,
              icon: Icons.error_outline,
              message: 'Sessions could not be listed: ${result.problem}',
            )
          else if (result.sessions.isEmpty)
            const EmptyState(
              icon: Icons.forum_outlined,
              title: 'No AI interviews yet',
              body: 'A session appears here once a candidate starts an '
                  'interview from the portal.',
            )
          else
            for (final session in result.sessions)
              Padding(
                padding: const EdgeInsets.only(bottom: Spacing.md),
                child: _SessionCard(
                  session: session,
                  onOpen: () => _open(session),
                ),
              ),
        ],
      ],
    );
  }
}

class _SessionCard extends StatelessWidget {
  const _SessionCard({required this.session, required this.onOpen});

  final InterviewSessionSummary session;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      child: InkWell(
        onTap: onOpen,
        borderRadius: BorderRadius.circular(Radii.surface),
        child: Padding(
          padding: const EdgeInsets.all(Spacing.lg),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Monogram(name: session.candidateId, diameter: 46),
              const SizedBox(width: Spacing.lg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(session.roleTitle, style: theme.textTheme.titleLarge),
                    const SizedBox(height: 2),
                    Text(
                      'Candidate ${session.candidateId} · started '
                      '${_stamp(session.startedAt)}'
                      '${session.currentTopic == null ? '' : ' · on "${session.currentTopic}"'}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: Spacing.sm),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  _statusTag(context, session.status),
                  const SizedBox(height: Spacing.sm),
                  Text('${session.completionPercent}% covered',
                      style: theme.textTheme.bodySmall),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _stamp(DateTime time) {
    final l = time.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
  }
}

Widget _statusTag(BuildContext context, String status) {
  final evidence = context.evidence;
  final (String label, Color colour, IconData icon) = switch (status) {
    'complete' => ('Complete', evidence.verified, Icons.check_circle_outline),
    'abandoned' => ('Abandoned', evidence.disputed, Icons.cancel_outlined),
    _ => ('In progress', evidence.unmeasured, Icons.hourglass_top_outlined),
  };
  return Tag(label: label, tone: colour, icon: icon);
}

// ---------------------------------------------------------------------------
// Detail / transcript
// ---------------------------------------------------------------------------

class InterviewSessionDetailScreen extends StatefulWidget {
  const InterviewSessionDetailScreen({
    super.key,
    required this.store,
    required this.session,
  });

  final SupabaseInterviewSessionStore store;
  final InterviewSessionSummary session;

  @override
  State<InterviewSessionDetailScreen> createState() =>
      _InterviewSessionDetailScreenState();
}

class _InterviewSessionDetailScreenState
    extends State<InterviewSessionDetailScreen> {
  final _reportClient = InterviewReportClient();

  List<InterviewEventRecord>? _events;
  String? _problem;
  InterviewReport? _report;
  String? _reportProblem;

  /// Set once the redeeming code is found — null while loading, and stays
  /// null (section simply omitted) if this session predates codes or the
  /// lookup fails. See [SupabaseInterviewSessionStore.findCodeIdForSession].
  String? _codeId;

  @override
  void initState() {
    super.initState();
    _load();
    _loadReport();
    _loadCodeId();
  }

  Future<void> _loadCodeId() async {
    final codeId = await widget.store.findCodeIdForSession(widget.session.id);
    if (!mounted || codeId == null) return;
    setState(() => _codeId = codeId);
  }

  Future<void> _load() async {
    try {
      final events = await widget.store.listEvents(widget.session.id);
      if (!mounted) return;
      setState(() => _events = events);
    } catch (error) {
      if (!mounted) return;
      setState(() => _problem = error.toString());
    }
  }

  Future<void> _loadReport() async {
    try {
      final report = await _reportClient.fetch(widget.session.id);
      if (!mounted) return;
      setState(() => _report = report);
    } catch (error) {
      if (!mounted) return;
      setState(() => _reportProblem = error.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;

    return Scaffold(
      appBar: AppBar(
        title: Text(session.roleTitle),
        actions: const [HomeAppBarAction()],
      ),
      body: ShellPage(
        title: session.roleTitle,
        subtitle: 'Candidate ${session.candidateId} · ${session.status}',
        actions: [_statusTag(context, session.status)],
        children: [
          MetricStrip(
            children: [
              MetricCard(
                label: 'Coverage',
                value: '${session.completionPercent}',
                unit: '%',
                icon: Icons.pie_chart_outline,
                fraction: session.completionPercent / 100,
                qualifier: 'Topics attempted out of topics planned',
              ),
              MetricCard(
                label: 'Started',
                value: _stamp(session.startedAt),
                icon: Icons.schedule_outlined,
              ),
              MetricCard(
                label: 'Finished',
                value: session.finishedAt == null
                    ? '—'
                    : _stamp(session.finishedAt!),
                icon: Icons.event_available_outlined,
              ),
            ],
          ),
          const SizedBox(height: Spacing.section),
          SectionCard(
            title: 'Résumé',
            icon: Icons.description_outlined,
            description: 'The file this candidate actually uploaded when '
                'they applied — the same document the claims below were '
                'read from.',
            child: _ResumeSection(candidateId: session.candidateId),
          ),
          const SizedBox(height: Spacing.section),
          SectionCard(
            title: 'Report',
            icon: Icons.fact_check_outlined,
            description: 'One row per planned topic: the claim it probed, '
                'the strongest evidence quote from the candidate\'s own '
                'answer, and whether it held up. No score, no ranking — a '
                'topic with no outcome is one the interview never reached.',
            child: _reportProblem != null
                ? InlineNotice(
                    tone: NoticeTone.fault,
                    message: 'Report could not be read: $_reportProblem',
                  )
                : _report == null
                    ? const Padding(
                        padding: EdgeInsets.symmetric(vertical: Spacing.xl),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    : _reportBody(context, _report!),
          ),
          if (_codeId != null) ...[
            const SizedBox(height: Spacing.section),
            SectionCard(
              title: 'Email status',
              icon: Icons.mail_outline,
              description: 'Invitation and reminder delivery for the '
                  'interview code that started this session.',
              child: _EmailStatusSection(codeId: _codeId!),
            ),
          ],
          const SizedBox(height: Spacing.section),
          SectionCard(
            title: 'Transcript',
            icon: Icons.forum_outlined,
            description: 'Every question, answer, and verdict, in the order '
                'they happened. Each answer\'s verdict states whether the '
                'model judged it grounded in the candidate\'s own words — '
                'never a rating of the person.',
            child: _problem != null
                ? InlineNotice(
                    tone: NoticeTone.fault,
                    message: 'Transcript could not be read: $_problem',
                  )
                : _events == null
                    ? const Padding(
                        padding: EdgeInsets.symmetric(vertical: Spacing.xl),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    : _transcript(context, _events!),
          ),
        ],
      ),
    );
  }

  Widget _reportBody(BuildContext context, InterviewReport report) {
    final theme = Theme.of(context);
    final evidence = context.evidence;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final topic in report.topics)
          Padding(
            padding: const EdgeInsets.only(bottom: Spacing.lg),
            child: Container(
              padding: const EdgeInsets.all(Spacing.lg),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(Radii.control),
                border: Border.all(color: theme.dividerColor),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(topic.topic,
                            style: theme.textTheme.titleMedium),
                      ),
                      _outcomeTag(context, topic.outcome),
                    ],
                  ),
                  const SizedBox(height: Spacing.xs),
                  Text('Claim: "${topic.claimText}"',
                      style: theme.textTheme.bodySmall),
                  if (topic.outcome == null)
                    Padding(
                      padding: const EdgeInsets.only(top: Spacing.sm),
                      child: Text(
                        'Not reached — the interview ended before this '
                        'topic was asked.',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: evidence.unmeasured),
                      ),
                    )
                  else ...[
                    const SizedBox(height: Spacing.sm),
                    if (topic.evidenceQuote != null)
                      Text('"${topic.evidenceQuote}"',
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(fontStyle: FontStyle.italic)),
                    const SizedBox(height: Spacing.xs),
                    Text(
                      '${topic.reason ?? ''} · ${topic.attempts} attempt'
                      '${topic.attempts == 1 ? '' : 's'}'
                      '${topic.confidence == null ? '' : ' · confidence ${(topic.confidence! * 100).round()}%'}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ],
              ),
            ),
          ),
        if (report.rejectedUngroundedTopics.isNotEmpty)
          InlineNotice(
            tone: NoticeTone.caution,
            message: 'The planner proposed but discarded '
                '${report.rejectedUngroundedTopics.length} topic(s) with no '
                'claim to tie them to: '
                '${report.rejectedUngroundedTopics.join('; ')}',
          ),
      ],
    );
  }

  Widget _outcomeTag(BuildContext context, String? outcome) {
    final evidence = context.evidence;
    final (String label, Color colour, IconData icon) = switch (outcome) {
      'supported' => ('Supported', evidence.verified, Icons.check_circle_outline),
      'not_supported' => ('Not supported', evidence.unmeasured, Icons.remove_circle_outline),
      _ => ('Not reached', evidence.notExamined, Icons.help_outline),
    };
    return Tag(label: label, tone: colour, icon: icon);
  }

  Widget _transcript(BuildContext context, List<InterviewEventRecord> events) {
    if (events.isEmpty) {
      return const Text('No events recorded for this session.');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < events.length; i++)
          TimelineEntry(
            isLast: i == events.length - 1,
            tone: _tone(context, events[i].eventType),
            title: _title(events[i].eventType),
            meta: _stamp(events[i].createdAt),
            body: _body(events[i]),
          ),
      ],
    );
  }

  Color? _tone(BuildContext context, String type) {
    final evidence = context.evidence;
    return switch (type) {
      'answer' => Theme.of(context).colorScheme.secondary,
      'analysis' => evidence.verified,
      'session_abandoned' => evidence.disputed,
      _ => null,
    };
  }

  String _title(String type) => switch (type) {
        'session_started' => 'Interview started',
        'question' => 'Question asked',
        'followup' => 'Follow-up asked',
        'answer' => 'Candidate answered',
        'analysis' => 'Answer analyzed',
        'coverage_update' => 'Coverage updated',
        'session_complete' => 'Interview complete',
        'session_abandoned' => 'Interview abandoned',
        _ => type,
      };

  String _body(InterviewEventRecord event) {
    final p = event.payload;
    return switch (event.eventType) {
      'question' || 'followup' =>
        '${p['question'] ?? ''}\non: "${p['topic'] ?? ''}"',
      'answer' => (p['answer_text'] as String?) ?? '',
      'analysis' => '${(p['supported'] as bool?) == true ? 'Supported' : 'Not supported'} '
          '— ${p['reason'] ?? ''}',
      'coverage_update' =>
        '${p['completion_percent'] ?? 0}% covered · '
            '${(p['remaining'] as List?)?.length ?? 0} topic(s) remaining',
      'session_abandoned' => (p['reason'] as String?) ?? '',
      _ => '',
    };
  }

  static String _stamp(DateTime time) {
    final l = time.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
  }
}

// ---------------------------------------------------------------------------
// Email status (Ticket 21)
// ---------------------------------------------------------------------------

/// The candidate's uploaded résumé, fetched through the gateway ([
/// CandidateResumeClient]) since the storage bucket that holds it has no
/// client-side read policy. Three states: loading, none on file (not an
/// error — most candidates haven't uploaded one at every pipeline stage),
/// and present with a Download action.
class _ResumeSection extends StatefulWidget {
  const _ResumeSection({required this.candidateId});

  final String candidateId;

  @override
  State<_ResumeSection> createState() => _ResumeSectionState();
}

class _ResumeSectionState extends State<_ResumeSection> {
  final _client = CandidateResumeClient();
  CandidateResume? _resume;
  String? _error;
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final resume = await _client.fetch(widget.candidateId);
      if (!mounted) return;
      setState(() {
        _resume = resume;
        _error = null;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '$error';
        _loading = false;
      });
    }
  }

  Future<void> _download() async {
    final resume = _resume;
    if (resume == null) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _saving = true);
    try {
      final path =
          await writeBinaryExport(resume.bytes, filename: resume.filename);
      messenger.showSnackBar(SnackBar(
        duration: const Duration(seconds: 10),
        content: Text('Résumé saved to $path'),
        action: SnackBarAction(
          label: 'Copy path',
          onPressed: () => Clipboard.setData(ClipboardData(text: path)),
        ),
      ));
    } catch (error) {
      messenger.showSnackBar(SnackBar(
        backgroundColor: Colors.red.shade800,
        duration: const Duration(seconds: 8),
        content: Text('Could not save the résumé: $error'),
      ));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: Spacing.sm),
        child: SizedBox(
          height: 16,
          width: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    if (_error != null) {
      return InlineNotice(
        tone: NoticeTone.caution,
        message: 'Résumé unavailable: $_error',
      );
    }

    final resume = _resume;
    if (resume == null) {
      return Text(
        'No résumé on file for this candidate.',
        style: theme.textTheme.bodySmall,
      );
    }

    return Row(
      children: [
        Icon(Icons.picture_as_pdf_outlined,
            size: 18, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: Spacing.sm),
        Expanded(
          child: Text(resume.filename, style: theme.textTheme.bodyMedium),
        ),
        if (exportSupported)
          OutlinedButton.icon(
            onPressed: _saving ? null : _download,
            icon: _saving
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.download_outlined, size: 16),
            label: const Text('Download'),
          ),
      ],
    );
  }
}

/// Invitation + reminder delivery status for one interview code, with a
/// Resend button. Used both right after a code is generated
/// ([_GeneratedCodeDialog]) and later, when reviewing a session that came
/// from a redeemed code ([InterviewSessionDetailScreen]).
class _EmailStatusSection extends StatefulWidget {
  const _EmailStatusSection({required this.codeId});

  final String codeId;

  @override
  State<_EmailStatusSection> createState() => _EmailStatusSectionState();
}

class _EmailStatusSectionState extends State<_EmailStatusSection> {
  final _client = EmailStatusClient();
  List<EmailDeliveryStatus>? _emails;
  String? _error;
  bool _resending = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final emails = await _client.listForCode(widget.codeId);
      if (!mounted) return;
      setState(() {
        _emails = emails;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = '$error');
    }
  }

  Future<void> _resend() async {
    setState(() => _resending = true);
    try {
      await _client.resendInvitation(widget.codeId);
    } catch (_) {
      // The reload below will show the row's own failed status either
      // way — nothing extra to surface here.
    }
    if (!mounted) return;
    setState(() => _resending = false);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_error != null) {
      return InlineNotice(
        tone: NoticeTone.caution,
        message: 'Email status unavailable: $_error',
      );
    }

    final emails = _emails;
    if (emails == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: Spacing.sm),
        child: SizedBox(
          height: 16,
          width: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (emails.isEmpty)
          Text('No email has been sent for this code yet.',
              style: theme.textTheme.bodySmall)
        else
          for (final email in emails) _emailRow(context, email),
        const SizedBox(height: Spacing.sm),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _resending ? null : _resend,
            icon: _resending
                ? const SizedBox(
                    height: 14,
                    width: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.send, size: 16),
            label: Text(_resending ? 'Resending…' : 'Resend invitation'),
          ),
        ),
      ],
    );
  }

  Widget _emailRow(BuildContext context, EmailDeliveryStatus email) {
    final theme = Theme.of(context);
    final evidence = context.evidence;
    final (String label, Color colour, IconData icon) = switch (email.status) {
      'sent' => ('Sent', evidence.verified, Icons.check_circle_outline),
      'failed' => ('Failed', evidence.disputed, Icons.error_outline),
      _ => ('Pending', evidence.unmeasured, Icons.hourglass_top_outlined),
    };

    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 15, color: colour),
              const SizedBox(width: Spacing.xs),
              Expanded(child: Text(_typeLabel(email.emailType))),
              Tag(label: label, tone: colour, icon: icon),
            ],
          ),
          if (email.status == 'failed' && email.lastError != null)
            Padding(
              padding: const EdgeInsets.only(left: 23, top: 2),
              child: Text(
                email.lastError!,
                style: theme.textTheme.bodySmall?.copyWith(color: evidence.disputed),
              ),
            ),
        ],
      ),
    );
  }

  static String _typeLabel(String type) => switch (type) {
        'invitation' => 'Invitation',
        'reminder_1h' => 'Reminder (1 hour before)',
        'reminder_30m' => 'Reminder (30 minutes before)',
        _ => type,
      };
}

// ---------------------------------------------------------------------------
// Generate-code dialogs
// ---------------------------------------------------------------------------

class _GenerateCodeDialog extends StatefulWidget {
  const _GenerateCodeDialog();

  @override
  State<_GenerateCodeDialog> createState() => _GenerateCodeDialogState();
}

class _GenerateCodeDialogState extends State<_GenerateCodeDialog> {
  final _candidateId = TextEditingController();
  final _roleTitle = TextEditingController();

  @override
  void dispose() {
    _candidateId.dispose();
    _roleTitle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Generate an interview code'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'The candidate must already have a resume-derived AI profile '
            '(see the resume pipeline). This does not create one.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: Spacing.lg),
          TextField(
            controller: _candidateId,
            decoration: const InputDecoration(labelText: 'Candidate id'),
          ),
          const SizedBox(height: Spacing.md),
          TextField(
            controller: _roleTitle,
            decoration: const InputDecoration(labelText: 'Role'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final candidateId = _candidateId.text.trim();
            final roleTitle = _roleTitle.text.trim();
            if (candidateId.isEmpty || roleTitle.isEmpty) return;
            Navigator.of(context)
                .pop((candidateId: candidateId, roleTitle: roleTitle));
          },
          child: const Text('Generate'),
        ),
      ],
    );
  }
}

class _GeneratedCodeDialog extends StatelessWidget {
  const _GeneratedCodeDialog({required this.generated});

  final GeneratedInterviewCode generated;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Interview code generated'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(generated.roleTitle, style: theme.textTheme.bodySmall),
          const SizedBox(height: Spacing.md),
          SelectableText(
            generated.code,
            style: theme.textTheme.headlineMedium?.copyWith(letterSpacing: 3),
          ),
          const SizedBox(height: Spacing.md),
          Text(
            'Expires ${_dialogStamp(generated.expiresAt)} · '
            '${generated.maxAttempts} attempt(s) allowed.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: Spacing.lg),
          Text('Email', style: theme.textTheme.titleSmall),
          const SizedBox(height: Spacing.sm),
          _EmailStatusSection(codeId: generated.id),
        ],
      ),
      actions: [
        TextButton.icon(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: generated.code));
            ScaffoldMessenger.of(context)
                .showSnackBar(const SnackBar(content: Text('Code copied')));
          },
          icon: const Icon(Icons.copy, size: 16),
          label: const Text('Copy'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    );
  }

  static String _dialogStamp(DateTime time) {
    final l = time.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
  }
}
