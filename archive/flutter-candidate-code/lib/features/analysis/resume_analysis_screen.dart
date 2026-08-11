/// Resume analysis: read a file, show what was found, let the candidate confirm.
///
/// ## The mockup, and what is honest about it
///
/// The design for this screen is mostly good and mostly kept: a drop target, the
/// document on the left, extracted skills and gaps on the right, and a panel
/// showing what the reader concluded. Three things changed.
///
/// **The "ATS Alignment: 88 / EXCELLENT" ring is gone.** Its replacement is the
/// one proportion this pipeline can actually report — **extraction grounding**:
/// of the lines the model produced, how many appear verbatim in the resume. That
/// is a real, checkable number, and it is the number that matters, because the
/// failure mode of a language model reading a CV is inventing a plausible
/// achievement the person never wrote.
///
/// **The highlighted metrics in the document body are gone.** The mockup drew
/// gold highlights over "200M+ requests daily" and "42%", as though the system
/// had verified those figures. It has not looked at them at all. What is
/// highlighted here instead is the span each *claim* was taken from, which is
/// something the extractor really did determine.
///
/// **"Missing skills: REQUIRED / BONUS" is gone**, because nothing on this
/// screen knows what any role requires. Roles are authored by a human on the
/// Roles screen, and gaps are reported there against a named role. What this
/// screen reports instead is which claims carry no skill tag — a fact about the
/// extraction, not a judgement about the person.
///
/// **"Generate Validation Test" now generates something.** It renders the real
/// probe ladder from [QuestionBank] for each confirmed claim, so the candidate can
/// see exactly what they will be asked before agreeing to be asked it.
library;

import 'package:flutter/material.dart';

import '../../core/claims/claim.dart';
import '../../core/claims/claim_extractor.dart';
import '../../core/claims/claim_extractor_factory.dart';
import '../../core/design/app_theme.dart';
import '../../core/interview/question_bank.dart';
import '../../core/session/session_draft.dart';
import '../../ui/app_shell.dart';
import '../../ui/components.dart';
import '../../ui/patterns.dart';
import '../resume/resume_pick.dart';

class ResumeAnalysisScreen extends StatefulWidget {
  const ResumeAnalysisScreen({
    super.key,
    required this.draft,
    this.extractor,
  });

  final SessionDraft draft;

  /// Injectable so a widget test can drive this screen without a local model
  /// running. Defaults to the real one.
  final ClaimExtractor? extractor;

  @override
  State<ResumeAnalysisScreen> createState() => _ResumeAnalysisScreenState();
}

class _ResumeAnalysisScreenState extends State<ResumeAnalysisScreen> {
  late final ClaimExtractor _extractor =
      widget.extractor ?? createDefaultClaimExtractor();

  bool _picking = false;

  @override
  void initState() {
    super.initState();
    widget.draft.addListener(_onDraftChanged);
  }

  @override
  void dispose() {
    widget.draft.removeListener(_onDraftChanged);
    super.dispose();
  }

  void _onDraftChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _pick() async {
    setState(() => _picking = true);
    ResumePick? pick;
    try {
      pick = await pickResume();
    } finally {
      if (mounted) setState(() => _picking = false);
    }
    if (pick == null || !mounted) return;

    final draft = widget.draft;
    draft.beginPick(pick);
    if (!pick.hasText) return;

    final extraction = await _extractor.extract(
      pick.text!,
      source: 'Resume: ${pick.fileName}',
    );
    // The extractor takes seconds; the draft itself discards this if a newer
    // file was chosen in the meantime.
    if (!mounted) return;
    draft.completeExtraction(pick, extraction);
  }

  void _showProbes() {
    final claims = widget.draft.confirmedClaims;
    showDialog<void>(
      context: context,
      builder: (context) => _ProbePreviewDialog(claims: claims),
    );
  }

  @override
  Widget build(BuildContext context) {
    final draft = widget.draft;
    final pick = draft.pick;

    return ShellPage(
      title: 'Resume analysis',
      subtitle: 'A model running on this machine reads the file and proposes '
          'claims. Nothing is uploaded, and nothing is used until you confirm '
          'it in your own words.',
      actions: [
        if (pick != null)
          OutlinedButton.icon(
            onPressed: draft.clearResume,
            icon: const Icon(Icons.restart_alt, size: 18),
            label: const Text('Start over'),
          ),
      ],
      children: [
        DropZone(
          headline: pick == null
              ? 'Choose a resume to analyse'
              : 'Choose a different resume',
          detail: 'PDF, DOCX, TXT, or Markdown. Text is read on this device by '
              'a local model; no network request is made.',
          capabilities: const [
            'Claim extraction',
            'Verbatim grounding check',
            'Skill tagging',
            'Probe generation',
          ],
          busy: _picking || draft.extracting,
          onTap: _pick,
        ),
        if (pick == null) ...[
          const SizedBox(height: Spacing.xl),
          const InlineNotice(
            message: 'Until a resume is read, a session runs on two clearly '
                'labelled demo claims so the app is still demonstrable. Those '
                'are marked as demo data everywhere they appear.',
          ),
        ] else ...[
          const SizedBox(height: Spacing.xl),
          if (draft.extracting)
            const InlineNotice(
              icon: Icons.hourglass_empty,
              message: 'Reading this resume with a model running on this '
                  'machine. The first run after a cold start takes noticeably '
                  'longer while weights load.',
            )
          else if (!pick.hasText)
            InlineNotice(
              tone: NoticeTone.fault,
              icon: Icons.error_outline,
              message: pick.extractionNote ??
                  'This file could not be read as text, so no claim could be '
                      'taken from it.',
            )
          else
            ..._analysed(context, pick),
        ],
      ],
    );
  }

  List<Widget> _analysed(BuildContext context, ResumePick pick) {
    final draft = widget.draft;

    return [
      LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 920;
          final left = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _documentCard(context, pick),
              const SizedBox(height: Spacing.xl),
              _reviewCard(context),
            ],
          );
          final right = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _groundingCard(context),
              const SizedBox(height: Spacing.xl),
              _skillsCard(context),
              const SizedBox(height: Spacing.xl),
              _nextCard(context),
            ],
          );

          if (!wide) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [right, const SizedBox(height: Spacing.xl), left],
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
      if (draft.confirmedClaims.isNotEmpty) ...[
        const SizedBox(height: Spacing.section),
        InlineNotice(
          icon: Icons.check_circle_outline,
          message: '${draft.confirmedClaims.length} claim(s) confirmed. The '
              'next session will examine these and nothing else.',
          action: TextButton(
            onPressed: () =>
                AppShellController.of(context)?.goTo('New session'),
            child: const Text('Go to setup'),
          ),
        ),
      ],
    ];
  }

  /// The document, with the source span of each extracted claim marked.
  Widget _documentCard(BuildContext context, ResumePick pick) {
    final theme = Theme.of(context);
    final text = pick.text ?? '';
    final claims = widget.draft.review.map((r) => r.claim.text).toList();

    return SectionCard(
      title: pick.fileName,
      icon: Icons.article_outlined,
      description: 'The text as read from the file. Highlights mark the spans '
          'the claims below were taken from — nothing here has been verified, '
          'only located.',
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 460),
        child: SingleChildScrollView(
          child: SelectableText.rich(
            TextSpan(children: _highlight(context, text, claims)),
            style: theme.textTheme.bodyMedium,
          ),
        ),
      ),
    );
  }

  /// Marks each claim's text where it occurs in the source.
  ///
  /// Only exact matches are highlighted. A claim the extractor produced that is
  /// not present verbatim is exactly what the grounding gate rejects, so it
  /// should not appear in [claims] at all — and if one ever did, showing it
  /// unhighlighted is the correct, visible failure.
  List<TextSpan> _highlight(
    BuildContext context,
    String source,
    List<String> claims,
  ) {
    final brand = context.brand;

    // Collect non-overlapping match ranges, longest claim first so a claim
    // contained inside another does not split its parent's highlight.
    final ordered = [...claims]
      ..sort((a, b) => b.length.compareTo(a.length));
    final ranges = <(int, int)>[];

    for (final claim in ordered) {
      final needle = claim.trim();
      if (needle.length < 8) continue;
      final at = source.indexOf(needle);
      if (at < 0) continue;
      final end = at + needle.length;
      final overlaps = ranges.any((r) => at < r.$2 && end > r.$1);
      if (!overlaps) ranges.add((at, end));
    }

    ranges.sort((a, b) => a.$1.compareTo(b.$1));

    final spans = <TextSpan>[];
    var cursor = 0;
    for (final (start, end) in ranges) {
      if (start > cursor) {
        spans.add(TextSpan(text: source.substring(cursor, start)));
      }
      spans.add(TextSpan(
        text: source.substring(start, end),
        style: TextStyle(
          backgroundColor: brand.accent.withValues(alpha: 0.22),
          fontWeight: FontWeight.w600,
        ),
      ));
      cursor = end;
    }
    if (cursor < source.length) {
      spans.add(TextSpan(text: source.substring(cursor)));
    }
    return spans;
  }

  /// The editable review list — the load-bearing human check in the pipeline.
  Widget _reviewCard(BuildContext context) {
    final theme = Theme.of(context);
    final draft = widget.draft;
    final extraction = draft.extraction;

    if (draft.review.isEmpty) {
      return SectionCard(
        title: 'Claims found',
        icon: Icons.checklist_outlined,
        child: Text(
          'No candidate claims were found in this file. A session will run on '
          'the labelled demo claims until a resume with readable assertions is '
          'attached.',
          style: theme.textTheme.bodySmall,
        ),
      );
    }

    final keeping = draft.review.where((r) => r.contributes).length;

    return SectionCard(
      title: 'Claims found — review before use',
      icon: Icons.checklist_outlined,
      description: '${extraction?.kind.label ?? 'Unknown'} — '
          '${extraction?.kind.description ?? ''} Edit or remove anything that '
          'is not a real claim before the interview uses it.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (extraction?.degradedReason != null) ...[
            InlineNotice(
              tone: NoticeTone.fault,
              message: 'The local model was not used: '
                  '${extraction!.degradedReason}. These claims came from text '
                  'rules instead, which cannot read for meaning.',
            ),
            const SizedBox(height: Spacing.lg),
          ],
          for (final item in draft.review)
            Padding(
              padding: const EdgeInsets.only(bottom: Spacing.md),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Checkbox(
                    value: item.keep,
                    onChanged: (checked) =>
                        draft.setKeep(item, checked ?? false),
                  ),
                  Expanded(
                    child: TextField(
                      controller: item.controller,
                      enabled: item.keep,
                      maxLines: null,
                      style: theme.textTheme.bodyMedium,
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        isDense: true,
                        helperText: item.claim.skill != null
                            ? 'Tagged: ${item.claim.skill}'
                            : 'No skill tag — still examined, just not grouped '
                                'by skill',
                        helperMaxLines: 2,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: Spacing.sm),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: keeping == 0 ? null : draft.confirmReviewed,
              icon: const Icon(Icons.check, size: 18),
              label: Text(
                draft.confirmedClaims.isEmpty
                    ? 'Use these $keeping claim(s)'
                    : 'Update (${draft.confirmedClaims.length} confirmed)',
              ),
            ),
          ),
          if (keeping == 0)
            Text(
              'Nothing is selected, so there is nothing to confirm.',
              textAlign: TextAlign.right,
              style: theme.textTheme.bodySmall,
            ),
        ],
      ),
    );
  }

  /// Extraction grounding — the honest replacement for the mockup's ATS score.
  Widget _groundingCard(BuildContext context) {
    final theme = Theme.of(context);
    final extraction = widget.draft.extraction;

    if (extraction == null) {
      return SectionCard(
        title: 'Extraction grounding',
        icon: Icons.rule,
        child: Text('Nothing extracted yet.', style: theme.textTheme.bodySmall),
      );
    }

    final kept = extraction.claims.length;
    final rejected = extraction.rejectedUngrounded.length;
    final produced = kept + rejected;

    return SectionCard(
      title: 'Extraction grounding',
      icon: Icons.rule,
      description: 'Of the lines the reader produced, how many appear word for '
          'word in your resume. Anything that did not was discarded — a claim '
          'has to be in your own words to be used.',
      child: Column(
        children: [
          Center(
            child: RingGauge(
              diameter: 128,
              fraction: produced == 0 ? null : kept / produced,
              caption: 'grounded',
              centreLabel: produced == 0 ? null : '$kept/$produced',
              unavailableNote: 'nothing\nproduced',
            ),
          ),
          const SizedBox(height: Spacing.lg),
          KeyValueRow(label: 'Kept as claims', value: '$kept'),
          KeyValueRow(
            label: 'Discarded as ungrounded',
            value: '$rejected',
            tone: rejected == 0 ? null : context.evidence.unmeasured,
          ),
          KeyValueRow(
            label: 'Reader used',
            value: extraction.kind.label,
            monospaceValue: false,
          ),
          if (extraction.rejectedUngrounded.isNotEmpty) ...[
            const SizedBox(height: Spacing.md),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(bottom: Spacing.sm),
              title: Text(
                'See what was discarded',
                style: theme.textTheme.titleSmall,
              ),
              children: [
                for (final line in extraction.rejectedUngrounded)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Spacing.sm),
                    child: Text(
                      '"$line"',
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _skillsCard(BuildContext context) {
    final theme = Theme.of(context);
    final review = widget.draft.review;

    final tagged = <String>{
      for (final item in review)
        if ((item.claim.skill ?? '').trim().isNotEmpty)
          item.claim.skill!.trim(),
    }.toList()
      ..sort();

    final untagged =
        review.where((r) => (r.claim.skill ?? '').trim().isEmpty).length;

    return SectionCard(
      title: 'Skill tags found',
      icon: Icons.sell_outlined,
      description: 'Tags the reader attached to your claims. They are used to '
          'group evidence and to pick a relevant task — not to score anything.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (tagged.isEmpty)
            Text(
              'No claim carried a skill tag. Every claim is still examined; it '
              'just cannot be grouped by skill.',
              style: theme.textTheme.bodySmall,
            )
          else
            Wrap(
              spacing: Spacing.sm,
              runSpacing: Spacing.sm,
              children: [for (final skill in tagged) Tag(label: skill)],
            ),
          if (untagged > 0) ...[
            const SizedBox(height: Spacing.lg),
            Text(
              '$untagged claim(s) carry no tag. To check a specific role\'s '
              'requirements, define the role on the Roles screen — gaps are '
              'reported there against a list you wrote, not guessed here.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ],
      ),
    );
  }

  Widget _nextCard(BuildContext context) {
    final theme = Theme.of(context);
    final confirmed = widget.draft.confirmedClaims;

    return SectionCard(
      title: 'What you will be asked',
      icon: Icons.quiz_outlined,
      description: 'The probe ladder is deterministic and generated from your '
          'confirmed claims. You can read it before agreeing to it.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            confirmed.isEmpty
                ? 'Confirm some claims first — the questions are derived from '
                    'them, so there is nothing to generate yet.'
                : '${confirmed.length} confirmed claim(s) will each get an '
                    'opening, deepening, and verifying question.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: Spacing.md),
          OutlinedButton.icon(
            onPressed: confirmed.isEmpty ? null : _showProbes,
            icon: const Icon(Icons.visibility_outlined, size: 18),
            label: const Text('Preview the questions'),
          ),
        ],
      ),
    );
  }
}

/// Shows the real generated ladder for each confirmed claim.
class _ProbePreviewDialog extends StatelessWidget {
  const _ProbePreviewDialog({required this.claims});

  final List<Claim> claims;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const bank = QuestionBank();

    return AlertDialog(
      title: const Text('Questions for your confirmed claims'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Generated by the shipped question bank, not a model. The same '
                'claims always produce the same ladder.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: Spacing.lg),
              for (final claim in claims) ...[
                Text(claim.text, style: theme.textTheme.titleSmall),
                const SizedBox(height: Spacing.xs),
                if (QuestionBank.classify(claim) case final type?)
                  for (final question in bank.ladderFor(claim, type))
                    Padding(
                      padding: const EdgeInsets.only(
                        left: Spacing.md,
                        bottom: Spacing.sm,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${question.depth.name} · ${question.text}',
                            style: theme.textTheme.bodyMedium,
                          ),
                          if (question.checkableDetail.isNotEmpty)
                            Text(
                              'Checkable against: '
                              '${question.checkableDetail}',
                              style: theme.textTheme.bodySmall,
                            ),
                        ],
                      ),
                    )
                else
                  Padding(
                    padding: const EdgeInsets.only(
                      left: Spacing.md,
                      bottom: Spacing.sm,
                    ),
                    child: Text(
                      'This claim did not match any question type, so no ladder '
                      'was generated for it. It will be reported as not '
                      'examined rather than asked about with a generic '
                      'question.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                const SizedBox(height: Spacing.lg),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
