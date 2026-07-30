import 'package:flutter/material.dart';

import 'core/claims/claim.dart';
import 'core/claims/claim_audit.dart';
import 'core/claims/claim_extractor.dart';
import 'core/claims/ollama_claim_extractor.dart';
import 'core/design/app_theme.dart';
import 'core/persistence/audit_store.dart';
import 'core/persistence/json_codec.dart';
import 'core/persistence/store_factory.dart';
import 'core/verification/verification_result.dart';
import 'features/audit/claim_audit_screen.dart';
import 'features/common/empty_state.dart';
import 'features/enrolment/enrolment_screen.dart';
import 'features/interview/interview_screen.dart';
import 'features/resume/resume_pick.dart';
import 'features/resume/resume_upload_card.dart';
import 'features/sessions/session_history_screen.dart';
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

  runApp(CogniHireApp(
    store: store,
    storageLocation: location,
    storageIsDurable: durable,
  ));
}

class CogniHireApp extends StatelessWidget {
  const CogniHireApp({
    super.key,
    required this.store,
    required this.storageLocation,
    required this.storageIsDurable,
  });

  final AuditStore store;
  final String storageLocation;
  final bool storageIsDurable;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CogniHire',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      home: HomeScreen(
        store: store,
        storageLocation: storageLocation,
        storageIsDurable: storageIsDurable,
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

/// Entry point: enrol a reference face, then run a live verified session.
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.store,
    required this.storageLocation,
    required this.storageIsDurable,
  });

  final AuditStore store;
  final String storageLocation;
  final bool storageIsDurable;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  /// Demo claims, used only when no resume has been read. Kept so the app is
  /// still demonstrable without a file to hand — but no longer the *only*
  /// thing a session can run on, which is what they were before claim
  /// extraction existed.
  static const _demoClaims = [
    Claim(
      id: 'c1',
      text: 'Built and shipped a React dashboard used by 200+ staff',
      source: 'Demo claim — no resume read',
      skill: 'React',
    ),
    Claim(
      id: 'c2',
      text: 'Optimised Postgres queries, cutting p95 latency by 60%',
      source: 'Demo claim — no resume read',
      skill: 'PostgreSQL',
    ),
  ];

  /// Claims the candidate has reviewed and kept from their own resume. Empty
  /// until a resume with readable text is picked and confirmed.
  List<Claim> _extractedClaims = const [];

  /// Candidates awaiting review, never used to run a session directly. Each is
  /// editable and can be dropped before confirming; nothing here is trusted
  /// until the candidate has looked at it. That human check stays load-bearing
  /// whichever extractor ran — a local model is better than text rules at
  /// finding assertions, and still not a substitute for the person confirming
  /// these are their words.
  List<_ClaimReviewItem> _reviewCandidates = const [];

  /// The extraction behind [_reviewCandidates], kept for its provenance: which
  /// mechanism actually ran, whether it degraded, and what it refused.
  ClaimExtraction? _extraction;

  bool _extracting = false;

  final _extractor = OllamaClaimExtractor();

  /// What the session will actually examine: the candidate's own reviewed
  /// claims when there are any, otherwise the demo set.
  List<Claim> get _claims =>
      _extractedClaims.isNotEmpty ? _extractedClaims : _demoClaims;

  final _labelController = TextEditingController();

  EnrolmentProfile? _enrolment;

  /// Set when a stored enrolment exists but cannot be read. Kept distinct from
  /// "not enrolled": one is a choice, the other is a fault, and running a
  /// session unverified because of a fault should never look deliberate.
  String? _enrolmentError;

  bool _loadingEnrolment = true;

  /// Attached for reference only until claim extraction exists — see the
  /// note shown next to the upload card.
  ResumePick? _resumePick;

  /// Opt-in, defaults to false. This is a second, separate consent from
  /// identity verification (which is mandatory to run at all) — it governs
  /// whether this session's data may be used in the research dataset
  /// (`ML_REDESIGN.md` §5). Silence is not consent, so the box starts
  /// unchecked and the choice is logged explicitly either way.
  bool _researchConsent = false;

  @override
  void initState() {
    super.initState();
    _loadEnrolment();
    // Fire-and-forget: loading the model's weights costs ~40s cold and ~0.3s
    // warm, and the candidate is about to spend at least that long enrolling.
    // Paying it here means extraction feels instant instead of broken. Nothing
    // depends on the result, and a failure is handled at extraction time.
    _extractor.warmUp();
  }

  @override
  void dispose() {
    _labelController.dispose();
    for (final item in _reviewCandidates) {
      item.controller.dispose();
    }
    super.dispose();
  }

  Future<void> _onResumePicked(ResumePick pick) async {
    setState(() {
      _resumePick = pick;
      _extractedClaims = const [];
      _extraction = null;
      for (final item in _reviewCandidates) {
        item.controller.dispose();
      }
      _reviewCandidates = const [];
      _extracting = pick.hasText;
    });

    if (!pick.hasText) return;

    final extraction = await _extractor.extract(
      pick.text!,
      source: 'Resume: ${pick.fileName}',
    );

    // The extractor takes seconds; the user can have picked another file or left
    // the screen by now. Never setState on a dead widget, and never let a stale
    // result overwrite a newer pick.
    if (!mounted || _resumePick != pick) return;

    setState(() {
      _extracting = false;
      _extraction = extraction;
      _reviewCandidates = extraction.claims
          .map((c) => _ClaimReviewItem(claim: c))
          .toList();
    });
  }

  /// Copies whatever the candidate has kept and possibly edited into the set
  /// the session will actually run on. Discarded items and blanked-out text
  /// contribute nothing — there is no fallback to the original extracted
  /// wording once the candidate has removed it.
  void _confirmReviewedClaims() {
    setState(() {
      _extractedClaims = [
        for (final item in _reviewCandidates)
          if (item.keep && item.controller.text.trim().isNotEmpty)
            Claim(
              id: item.claim.id,
              text: item.controller.text.trim(),
              source: item.claim.source,
              skill: item.claim.skill,
            ),
      ];
    });
  }

  Widget _claimReviewSection(ThemeData theme) => Card(
        child: Padding(
          padding: const EdgeInsets.all(Spacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Claims found in this resume — review before use',
                style: theme.textTheme.titleSmall,
              ),
              const SizedBox(height: Spacing.xs),
              // Says which mechanism actually produced this list. A model and a
              // text rule have very different failure modes, and a reviewer
              // cannot calibrate their reading of the list without knowing
              // which one they are looking at.
              Text(
                '${_extraction?.kind.label ?? 'Unknown'} — '
                '${_extraction?.kind.description ?? ''} Edit or remove anything '
                'that is not a real claim before the interview uses it.',
                style: theme.textTheme.bodySmall,
              ),
              if (_extraction?.degradedReason != null) ...[
                const SizedBox(height: Spacing.sm),
                Text(
                  'The local model was not used: '
                  '${_extraction!.degradedReason}. These claims came from text '
                  'rules instead, which cannot read for meaning.',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.error),
                ),
              ],
              if (_extraction != null &&
                  _extraction!.rejectedUngrounded.isNotEmpty) ...[
                const SizedBox(height: Spacing.sm),
                Text(
                  'Discarded ${_extraction!.rejectedUngrounded.length} line(s) '
                  'the model produced that do not appear in your resume. A '
                  'claim has to be in your own words to be used.',
                  style: theme.textTheme.bodySmall,
                ),
              ],
              const SizedBox(height: Spacing.md),
              for (final item in _reviewCandidates)
                Padding(
                  padding: const EdgeInsets.only(bottom: Spacing.sm),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Checkbox(
                        value: item.keep,
                        onChanged: (checked) => setState(
                          () => item.keep = checked ?? false,
                        ),
                      ),
                      Expanded(
                        child: TextField(
                          controller: item.controller,
                          enabled: item.keep,
                          maxLines: null,
                          style: theme.textTheme.bodyMedium,
                          decoration: InputDecoration(
                            isDense: true,
                            helperText: item.claim.skill != null
                                ? 'Tagged: ${item.claim.skill}'
                                : null,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.tonal(
                  onPressed: _confirmReviewedClaims,
                  child: Text(
                    _extractedClaims.isEmpty
                        ? 'Use these claims'
                        : 'Update (${_extractedClaims.length} confirmed)',
                  ),
                ),
              ),
            ],
          ),
        ),
      );

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

  String get _label => _labelController.text.trim().isEmpty
      ? 'Unlabelled session'
      : _labelController.text.trim();

  /// Starts a session against an already-enrolled reference.
  ///
  /// Takes a non-null embedding by design: enrolment is a precondition for
  /// running at all, so there is no unverified path to reach this from.
  void _startInterview(List<double> embedding) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => InterviewScreen(
          claims: _claims,
          enrolledEmbedding: embedding,
          store: widget.store,
          candidateLabel: _label,
          researchConsentGranted: _researchConsent,
        ),
      ),
    );
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
                  claims: _claims,
                  enrolledEmbedding: capture.embedding,
                  store: widget.store,
                  candidateLabel: _label,
                  researchConsentGranted: _researchConsent,
                ),
              ),
            );

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

  /// Built once. The sample audit is stamped with wall-clock times, so
  /// rebuilding it on every frame would make its timestamps drift and its
  /// widgets churn for no reason.
  late final ClaimAudit _sample = _sampleAudit();

  @override
  Widget build(BuildContext context) {
    // Every surface of the app is a destination in the rail. That is the point:
    // a feature with no destination is visibly missing rather than silently
    // unreachable, which is how finished work went unshipped here before.
    return AppShell(
      destinations: [
        ShellDestination(
          icon: Icons.play_circle_outline,
          selectedIcon: Icons.play_circle_fill,
          label: 'New session',
          shortLabel: 'New',
          builder: _setupPage,
        ),
        ShellDestination(
          icon: Icons.history_outlined,
          selectedIcon: Icons.history,
          label: 'Past sessions',
          shortLabel: 'Past',
          builder: (_) => SessionHistoryScreen(
            store: widget.store,
            storageLocation: widget.storageLocation,
            storageIsDurable: widget.storageIsDurable,
          ),
        ),
        ShellDestination(
          icon: Icons.fact_check_outlined,
          selectedIcon: Icons.fact_check,
          label: 'Sample audit',
          shortLabel: 'Sample',
          builder: (_) => ClaimAuditScreen(
            audit: _sample,
            label: 'Sample audit — illustrative data, not a real candidate',
          ),
        ),
        ShellDestination(
          icon: Icons.monitor_heart_outlined,
          selectedIcon: Icons.monitor_heart,
          label: 'Telemetry',
          builder: (_) => const TaskScreen(),
        ),
      ],
    );
  }

  Widget _setupPage(BuildContext context) {
    final theme = Theme.of(context);

    return ShellPage(
      title: 'New session',
      subtitle: 'Continuous provenance for technical interviews — who did the '
          'work, how, and what could not be checked.',
      maxWidth: Measures.form,
      children: [
        SectionCard(
          title: 'Candidate',
          icon: Icons.badge_outlined,
          description: 'How this session is filed in Past sessions.',
          child: TextField(
            controller: _labelController,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(
              labelText: 'Candidate reference',
              hintText: 'e.g. Alice Nguyen — backend screen',
            ),
          ),
        ),
        const SizedBox(height: Spacing.md),

        // Two setup cards side by side when the window allows, stacked when it
        // does not — a specified collapse rather than a Row that happens to fit.
        ResponsiveColumns(
          minColumnWidth: 300,
          children: [
            _enrolmentCard(theme),
            ResumeUploadCard(onPicked: _onResumePicked),
          ],
        ),

        if (_resumePick != null) ...[
          const SizedBox(height: Spacing.md),
          if (_extracting)
            const InlineNotice(
              icon: Icons.hourglass_empty,
              message: 'Reading this resume with a model running on this '
                  'machine. Nothing is being uploaded.',
            )
          else if (_reviewCandidates.isNotEmpty)
            _claimReviewSection(theme)
          else
            InlineNotice(
              tone: _resumePick!.hasText ? NoticeTone.info : NoticeTone.caution,
              message: _resumePick!.hasText
                  ? 'No candidate claims found in this file — the interview '
                      'will run on the demo claims until you attach a resume '
                      'with readable assertions.'
                  : (_resumePick!.extractionNote ??
                      'This file could not be read.'),
            ),
        ],

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
                    ? 'A reference face is captured first. Every session runs '
                        'with identity verification — there is no unverified '
                        'mode.'
                    : 'Identity is re-checked throughout the session. Checks '
                        'that cannot be performed are reported as unmeasured, '
                        'never as passes.',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),

        if (_systemNotice(theme) != null) ...[
          const SizedBox(height: Spacing.xl),
          _systemNotice(theme)!,
        ],
      ],
    );
  }

  /// Surfaced only when something needs attention — matches the rest of the
  /// app's "report broken, stay quiet when fine" rule. The face-service URL
  /// and its `--dart-define` override are build-time developer config; they
  /// have no bearing on whether the product works and don't belong on a
  /// screen shown to a recruiter or mentor. Storage durability is only worth
  /// a line when it's *not* durable — the happy path needs no announcement.
  Widget? _systemNotice(ThemeData theme) {
    if (widget.storageIsDurable) return null;

    return Card(
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
  }

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
          value: _researchConsent,
          onChanged: (checked) =>
              setState(() => _researchConsent = checked ?? false),
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

/// One extracted-claim candidate under review: the original [claim] the
/// heuristic produced, an editable [controller] seeded with its text, and
/// whether the candidate has chosen to keep it. Nothing here is used by a
/// session until [_HomeScreenState._confirmReviewedClaims] copies it across.
class _ClaimReviewItem {
  _ClaimReviewItem({required this.claim})
      : controller = TextEditingController(text: claim.text),
        keep = true;

  final Claim claim;
  final TextEditingController controller;
  bool keep;
}
