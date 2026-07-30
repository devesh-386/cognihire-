import 'package:flutter/material.dart';

import '../../core/design/app_theme.dart';

/// A guided empty state: what's missing, why, and what to do about it.
///
/// A blank panel makes a user wonder whether the app is broken or they are.
/// Every empty surface in this app routes through here so the answer is always
/// on screen.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    this.actionLabel,
    this.onAction,
    this.tone = EmptyStateTone.neutral,
  });

  final IconData icon;
  final String title;
  final String body;

  /// Optional next step. Omitted when there genuinely isn't one — offering a
  /// dead button is worse than offering none.
  final String? actionLabel;
  final VoidCallback? onAction;

  final EmptyStateTone tone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colour = switch (tone) {
      EmptyStateTone.neutral => theme.colorScheme.onSurfaceVariant,
      EmptyStateTone.fault => theme.colorScheme.error,
    };

    return Center(
      child: ConstrainedBox(
        // ~46ch measure — keeps the explanation readable rather than running
        // edge to edge on a desktop window.
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(Spacing.xxl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: colour.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(Radii.surface),
                ),
                child: Icon(icon, size: 26, color: colour),
              ),
              const SizedBox(height: Spacing.lg),
              Text(
                title,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: Spacing.sm),
              Text(
                body,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
              ),
              if (actionLabel != null && onAction != null) ...[
                const SizedBox(height: Spacing.xl),
                FilledButton(onPressed: onAction, child: Text(actionLabel!)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

enum EmptyStateTone { neutral, fault }

/// A labelled section heading with optional supporting line.
///
/// Used instead of a bare `Text` so every section in the app gets the same
/// eyebrow-label / title / description rhythm rather than each screen
/// inventing its own.
class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.label,
    this.description,
    this.trailing,
  });

  final String label;
  final String? description;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(label.toUpperCase(), style: theme.textTheme.labelSmall),
            ),
            ?trailing,
          ],
        ),
        if (description != null) ...[
          const SizedBox(height: Spacing.xs),
          Text(description!, style: theme.textTheme.bodySmall),
        ],
      ],
    );
  }
}

/// A small status chip: icon + text, in a semantic colour.
///
/// Always carries a **text label**, never colour alone — a reviewer with a
/// colour-vision difference must be able to tell "verified" from "not checked"
/// without relying on hue.
class StatusChip extends StatelessWidget {
  const StatusChip({
    super.key,
    required this.icon,
    required this.label,
    required this.colour,
    this.background,
  });

  final IconData icon;
  final String label;
  final Color colour;
  final Color? background;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.md,
        vertical: Spacing.xs + 2,
      ),
      decoration: BoxDecoration(
        color: background ?? colour.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(Radii.pill),
        border: Border.all(color: colour.withValues(alpha: 0.28)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: colour),
          const SizedBox(width: Spacing.xs + 2),
          Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(color: colour),
          ),
        ],
      ),
    );
  }
}
