import 'package:flutter/material.dart';

import '../../core/design/app_theme.dart';
import '../../core/ml/decision_guards.dart';
import '../../core/ml/explanation_templater.dart';
import '../../ui/patterns.dart';
import '../../ui/tokens.dart';

/// One model decision, laid out for a human reviewer — Phase 3.5.
///
/// ## The guard suite is the screen, not a lint on it
///
/// This screen runs [DecisionGuards] before it renders anything, and if a
/// **blocking** violation is present it shows the violations *instead of* the
/// decision. That is the point of building 3.4d before 3.5: an unvalidated
/// model framed as a finding about a real person is not a warning to log, it is
/// a screen that must not exist. Non-blocking violations render alongside the
/// decision, because incomplete is not the same as false.
///
/// ## What is deliberately absent
///
/// No verdict chip, no letter grade, no traffic light over the whole decision.
/// The same rule the evidence graph holds: any single badge over this is a
/// hidden weight. What a reviewer gets is the probability the model actually
/// produced, the exact arithmetic behind it, what would have had to differ, and
/// — always last, always present for a synthetic model — the caveat.
class ModelDecisionScreen extends StatelessWidget {
  const ModelDecisionScreen({
    super.key,
    required this.decision,
    this.claimText,
  });

  final DecisionUnderReview decision;

  /// Shown in the app bar so the reviewer knows what the decision is about.
  final String? claimText;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final violations = DecisionGuards.check(decision);
    final blocking = violations.where((v) => v.isBlocking).toList();
    final warnings = violations.where((v) => !v.isBlocking).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Model decision'),
        actions: const [HomeAppBarAction()],
        bottom: claimText == null
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(28),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                      Spacing.lg, 0, Spacing.lg, Spacing.sm),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '"$claimText"',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(fontStyle: FontStyle.italic),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.all(Spacing.lg),
            children: blocking.isNotEmpty
                ? _withheld(context, blocking)
                : _decision(context, warnings),
          ),
        ),
      ),
    );
  }

  /// The refusal path. A reviewer sees why the decision is being withheld —
  /// never the decision itself, and never a vague "unavailable".
  List<Widget> _withheld(BuildContext context, List<GuardViolation> blocking) {
    final theme = Theme.of(context);
    final evidence = theme.extension<EvidenceColors>()!;
    return [
      _Panel(
        background: evidence.disputedContainer,
        foreground: evidence.disputed,
        icon: Icons.block_outlined,
        title: 'This decision is not shown',
        body: 'Showing it would state something untrue. The checks that '
            'failed are listed below; each is a property of how the decision '
            'would be presented, not of the arithmetic behind it.',
      ),
      const SizedBox(height: Spacing.lg),
      for (final v in blocking)
        Padding(
          padding: const EdgeInsets.only(bottom: Spacing.md),
          child: _ViolationTile(violation: v),
        ),
    ];
  }

  List<Widget> _decision(BuildContext context, List<GuardViolation> warnings) {
    final theme = Theme.of(context);
    final evidence = theme.extension<EvidenceColors>()!;
    final e = decision.explanation;
    final conformal = decision.conformal;

    return [
      Text(e.headline, style: theme.textTheme.titleMedium),
      const SizedBox(height: Spacing.lg),

      if (conformal != null) ...[
        _Panel(
          background: conformal.isAbstain
              ? evidence.unmeasuredContainer
              : evidence.notExaminedContainer,
          foreground: conformal.isAbstain
              ? evidence.unmeasured
              : evidence.notExamined,
          icon: conformal.isAbstain
              ? Icons.help_outline
              : Icons.check_circle_outline,
          title: conformal.isAbstain
              ? 'No answer at this confidence level'
              : 'Committed: '
                  '${conformal.committedLabel == true ? 'sufficient' : 'not sufficient'}',
          body: conformal.isAbstain
              ? 'The prediction set contains both answers, so at this '
                  'confidence level the model declines to choose. Abstaining is '
                  'a result, not a failure to compute one.'
              : 'The prediction set contains exactly one answer at this '
                  'confidence level.',
        ),
        const SizedBox(height: Spacing.lg),
      ],

      _SectionHeader(
        'What the model weighted',
        subtitle: 'Exact contributions to the decision — this is the '
            'arithmetic, not a summary of it.',
      ),
      for (final c in e.drivers)
        _DriverRow(
          label: ExplanationTemplater.humanise(c.feature),
          value: c.rawValue,
          contribution: c.contribution,
          maxMagnitude: e.drivers
              .map((d) => d.contribution.abs())
              .fold<double>(1e-9, (a, b) => a > b ? a : b),
        ),
      const SizedBox(height: Spacing.xl),

      _SectionHeader(
        'What would have had to differ',
        subtitle: 'Single-input moves, every other input held fixed.',
      ),
      for (final line in e.counterfactualLines)
        Padding(
          padding: const EdgeInsets.only(bottom: Spacing.sm),
          child: Text(line, style: theme.textTheme.bodyMedium),
        ),

      if (warnings.isNotEmpty) ...[
        const SizedBox(height: Spacing.xl),
        _SectionHeader(
          'Worth knowing',
          subtitle: 'Nothing above is false, but it is incomplete in these '
              'ways.',
        ),
        for (final v in warnings)
          Padding(
            padding: const EdgeInsets.only(bottom: Spacing.md),
            child: _ViolationTile(violation: v),
          ),
      ],

      if (e.caveat != null) ...[
        const SizedBox(height: Spacing.xl),
        _Panel(
          background: evidence.unmeasuredContainer,
          foreground: evidence.unmeasured,
          icon: Icons.science_outlined,
          title: 'Not a finding about a real person',
          body: e.caveat!,
        ),
      ],
      const SizedBox(height: Spacing.xl),
    ];
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title, {required this.subtitle});
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.titleSmall),
          const SizedBox(height: Spacing.xs),
          Text(subtitle,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}

/// One feature's push, as a signed bar either side of a centre line.
///
/// The bar is scaled against the largest contribution *shown*, so it encodes
/// relative magnitude within this decision and nothing else. It is deliberately
/// not scaled against some global maximum, which would silently imply a
/// comparison to other candidates that was never computed.
class _DriverRow extends StatelessWidget {
  const _DriverRow({
    required this.label,
    required this.value,
    required this.contribution,
    required this.maxMagnitude,
  });

  final String label;
  final double value;
  final double contribution;
  final double maxMagnitude;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final evidence = theme.extension<EvidenceColors>()!;
    final toward = contribution > 0;
    final colour = toward ? evidence.verified : evidence.disputed;
    final fraction = (contribution.abs() / maxMagnitude).clamp(0.0, 1.0);

    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(label,
                    style: theme.textTheme.bodyMedium,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis),
              ),
              const SizedBox(width: Spacing.sm),
              // Tabular figures: these run down the screen as a column the
              // reviewer compares against itself, and proportional digits make
              // that column wobble.
              Text(
                '${toward ? '+' : '−'}${contribution.abs().toStringAsFixed(2)}',
                style: context.numericStrong.copyWith(color: colour),
              ),
            ],
          ),
          const SizedBox(height: Spacing.xs),
          Row(
            children: [
              Expanded(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: FractionallySizedBox(
                    widthFactor: toward ? 0.0 : fraction,
                    child: Container(
                      height: 6,
                      decoration: BoxDecoration(
                        color: colour,
                        borderRadius: BorderRadius.circular(Radii.pill),
                      ),
                    ),
                  ),
                ),
              ),
              Container(width: 1, height: 12, color: theme.dividerColor),
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: FractionallySizedBox(
                    widthFactor: toward ? fraction : 0.0,
                    child: Container(
                      height: 6,
                      decoration: BoxDecoration(
                        color: colour,
                        borderRadius: BorderRadius.circular(Radii.pill),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.xs),
          Text(
            'observed value ${value.toStringAsFixed(2)}',
            style: context.numeric.copyWith(
              fontSize: theme.textTheme.bodySmall?.fontSize,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _ViolationTile extends StatelessWidget {
  const _ViolationTile({required this.violation});
  final GuardViolation violation;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final evidence = theme.extension<EvidenceColors>()!;
    final colour =
        violation.isBlocking ? evidence.disputed : evidence.unmeasured;
    return Container(
      padding: const EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        border: Border.all(color: colour.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(Radii.surface),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(violation.guard,
              style: theme.textTheme.labelLarge?.copyWith(color: colour)),
          const SizedBox(height: Spacing.xs),
          Text(violation.detail, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({
    required this.background,
    required this.foreground,
    required this.icon,
    required this.title,
    required this.body,
  });

  final Color background;
  final Color foreground;
  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(Spacing.lg),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(Radii.surface),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: foreground, size: 20),
          const SizedBox(width: Spacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style:
                        theme.textTheme.titleSmall?.copyWith(color: foreground)),
                const SizedBox(height: Spacing.xs),
                Text(body, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
