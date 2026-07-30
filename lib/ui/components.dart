/// The shared component layer — one source of truth for the recurring surfaces.
///
/// ## Why this file exists
///
/// Before it, each screen assembled its own card-with-a-heading, its own
/// icon-label-value row, its own bordered notice. They were all *nearly* the
/// same, which is the worst outcome: the differences were accidental rather
/// than meaningful, so the app looked slightly inconsistent everywhere without
/// any single screen looking wrong. Consistency at that scale cannot be
/// maintained by care; it has to be maintained by there being one widget.
///
/// The rule for adding to this file: a component belongs here when a second
/// screen needs it, not in anticipation of one.
library;

import 'package:flutter/material.dart';

import '../core/design/app_theme.dart';
import 'tokens.dart';

/// A titled content panel: eyebrow label, optional description, optional
/// trailing action, then the body.
///
/// This is the workhorse. Nearly every region of every screen is one of these,
/// which is what gives the app a single rhythm instead of a per-screen one.
class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    required this.title,
    required this.child,
    this.description,
    this.trailing,
    this.icon,
    this.padding = const EdgeInsets.all(Spacing.lg),
    this.tone = SectionTone.neutral,
  });

  final String title;
  final String? description;
  final Widget? trailing;
  final IconData? icon;
  final Widget child;
  final EdgeInsets padding;
  final SectionTone tone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final (Color? background, Color? border) = switch (tone) {
      SectionTone.neutral => (null, null),
      SectionTone.fault => (scheme.errorContainer, scheme.error),
      SectionTone.quiet => (scheme.surfaceContainerHighest, null),
    };

    return Card(
      color: background,
      shape: border == null
          ? null
          : RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(Radii.surface),
              side: BorderSide(color: border.withValues(alpha: 0.4)),
            ),
      child: Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 16, color: scheme.onSurfaceVariant),
                  const SizedBox(width: Spacing.sm),
                ],
                Expanded(
                  child: Text(
                    title.toUpperCase(),
                    style: theme.textTheme.labelSmall,
                  ),
                ),
                ?trailing,
              ],
            ),
            if (description != null) ...[
              const SizedBox(height: Spacing.xs),
              Text(description!, style: theme.textTheme.bodySmall),
            ],
            const SizedBox(height: Spacing.md),
            child,
          ],
        ),
      ),
    );
  }
}

enum SectionTone { neutral, quiet, fault }

/// A single reported figure with its label and an optional qualifier.
///
/// The figure uses tabular numerals so a row of these lines up, and the
/// qualifier exists because in this app a number very often needs a caveat
/// attached to it — "of 5 measured", "synthetic data" — and a caveat rendered
/// somewhere else on the screen is a caveat a reader can miss.
class StatTile extends StatelessWidget {
  const StatTile({
    super.key,
    required this.label,
    required this.value,
    this.qualifier,
    this.tone,
  });

  final String label;
  final String value;
  final String? qualifier;
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label.toUpperCase(), style: theme.textTheme.labelSmall),
        const SizedBox(height: Spacing.xs),
        Text(
          value,
          style: context.numericDisplay.copyWith(color: tone),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        if (qualifier != null) ...[
          const SizedBox(height: 2),
          Text(
            qualifier!,
            style: theme.textTheme.bodySmall,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ],
    );
  }
}

/// A label/value row where the values align into a column.
///
/// [monospaceValue] is on by default: these rows almost always carry figures,
/// timestamps, or identifiers, all of which are things a reader compares
/// vertically.
class KeyValueRow extends StatelessWidget {
  const KeyValueRow({
    super.key,
    required this.label,
    required this.value,
    this.tone,
    this.monospaceValue = true,
  });

  final String label;
  final String value;
  final Color? tone;
  final bool monospaceValue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Spacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.bodySmall,
            ),
          ),
          const SizedBox(width: Spacing.md),
          Text(
            value,
            textAlign: TextAlign.right,
            style: (monospaceValue
                    ? context.numeric
                    : theme.textTheme.bodyMedium ?? const TextStyle())
                .copyWith(
              color: tone,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// An inline notice: something the reader needs to know before trusting what is
/// next to it.
///
/// Deliberately not a snackbar or a dialog. A caveat about the data has to stay
/// on screen for as long as the data does — a message that auto-dismisses is a
/// message that was not really required reading.
class InlineNotice extends StatelessWidget {
  const InlineNotice({
    super.key,
    required this.message,
    this.icon = Icons.info_outline,
    this.tone = NoticeTone.info,
    this.action,
  });

  final String message;
  final IconData icon;
  final NoticeTone tone;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final colour = switch (tone) {
      NoticeTone.info => scheme.onSurfaceVariant,
      NoticeTone.caution => context.evidence.unmeasured,
      NoticeTone.fault => scheme.error,
    };

    return Container(
      padding: const EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(Radii.control),
        border: Border.all(color: colour.withValues(alpha: 0.25)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: colour),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.textTheme.bodyMedium?.color,
              ),
            ),
          ),
          if (action != null) ...[
            const SizedBox(width: Spacing.sm),
            action!,
          ],
        ],
      ),
    );
  }
}

enum NoticeTone { info, caution, fault }

/// A tappable destination row. Whole-row target, so it clears the 44pt minimum
/// comfortably rather than relying on the chevron being hit.
class NavTile extends StatelessWidget {
  const NavTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Radii.surface),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Spacing.lg,
            vertical: Spacing.md,
          ),
          child: Row(
            children: [
              Icon(icon, size: 20, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: Spacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: theme.textTheme.titleSmall),
                    const SizedBox(height: 1),
                    Text(subtitle, style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right,
                size: 20,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A horizontal proportion bar for a value known to lie in a fixed range.
///
/// Carries its own numeric label, always. A bar alone encodes a value in length
/// only, which a reader can misjudge and a screen reader cannot convey at all;
/// the number is the content and the bar is the annotation, not the reverse.
class ProportionBar extends StatelessWidget {
  const ProportionBar({
    super.key,
    required this.fraction,
    required this.label,
    this.tone,
    this.semanticLabel,
  });

  /// Clamped to [0, 1] on render — an out-of-range value is a bug upstream, and
  /// drawing a bar past its track would hide it.
  final double fraction;
  final String label;
  final Color? tone;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colour = tone ?? theme.colorScheme.tertiary;
    final clamped = fraction.isNaN ? 0.0 : fraction.clamp(0.0, 1.0);

    return Semantics(
      label: semanticLabel,
      value: label,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: context.numericStrong),
          const SizedBox(height: Spacing.xs),
          ClipRRect(
            borderRadius: BorderRadius.circular(Radii.pill),
            child: LinearProgressIndicator(
              value: clamped,
              minHeight: 6,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
              valueColor: AlwaysStoppedAnimation<Color>(colour),
            ),
          ),
        ],
      ),
    );
  }
}

/// Lays children out in columns when there is room and stacks them when there
/// is not.
///
/// Exists because the alternative — a `Row` that fits only because the window
/// happened to be wide — is precisely the bug that shipped an 83px overflow
/// once already. Here the collapse is the specified behaviour rather than
/// something the layout falls into.
class ResponsiveColumns extends StatelessWidget {
  const ResponsiveColumns({
    super.key,
    required this.children,
    this.spacing = Spacing.md,
    this.minColumnWidth = 260,
  });

  final List<Widget> children;
  final double spacing;
  final double minColumnWidth;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxWidth;
        final fits = ((available + spacing) / (minColumnWidth + spacing))
            .floor()
            .clamp(1, children.length);

        if (fits <= 1) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0) SizedBox(height: spacing),
                children[i],
              ],
            ],
          );
        }

        // Wrap rather than a single Row: with more children than columns the
        // remainder flows onto another line instead of being squeezed.
        final columnWidth =
            (available - spacing * (fits - 1)) / fits;
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [
            for (final child in children)
              SizedBox(width: columnWidth, child: child),
          ],
        );
      },
    );
  }
}
