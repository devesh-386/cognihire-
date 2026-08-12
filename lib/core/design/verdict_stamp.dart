/// The signature Case File component: a rubber-stamp mark for the four
/// evidence "sealed output states" a claim can carry.
///
/// This replaces the flat colour chip that previously rendered evidence
/// state (see `claim_audit_screen.dart`'s finding cards). A chip is UI
/// chrome; a stamp is a determination someone made and marked onto the
/// record — which is the actual product claim, so the visual metaphor is
/// not decorative. The ink-bleed look (double border, low-opacity fill,
/// slight rotation) is what keeps it from just being a chip with corners —
/// a real rubber stamp is never perfectly opaque or perfectly aligned.
library;

import 'package:flutter/material.dart';

import 'app_theme.dart';

enum VerdictKind {
  verified,
  disputed,
  unmeasured,
  notExamined;

  String get label => switch (this) {
        VerdictKind.verified => 'VERIFIED',
        VerdictKind.disputed => 'DISPUTED',
        VerdictKind.unmeasured => 'UNMEASURED',
        VerdictKind.notExamined => 'NOT EXAMINED',
      };
}

/// A rotated, inked stamp mark for [kind].
///
/// [dense] shrinks padding/typography for use inline in list rows or table
/// cells, where a full-size stamp would overwhelm the row.
class VerdictStamp extends StatelessWidget {
  const VerdictStamp({
    super.key,
    required this.kind,
    this.dense = false,
  });

  final VerdictKind kind;
  final bool dense;

  Color _colorFor(BuildContext context) {
    final evidence = context.evidence;
    return switch (kind) {
      VerdictKind.verified => evidence.verified,
      VerdictKind.disputed => evidence.disputed,
      VerdictKind.unmeasured => evidence.unmeasured,
      VerdictKind.notExamined => evidence.notExamined,
    };
  }

  @override
  Widget build(BuildContext context) {
    final color = _colorFor(context);
    final theme = Theme.of(context);

    final textStyle = AppTypography.data(
      (dense ? theme.textTheme.labelSmall : theme.textTheme.labelMedium)
          ?.copyWith(
        color: color,
        fontWeight: FontWeight.w700,
        letterSpacing: dense ? 0.8 : 1.4,
      ),
    );

    final horizontalPad = dense ? Spacing.sm : Spacing.md;
    final verticalPad = dense ? 2.0 : Spacing.xs;

    // Not-examined is deliberately the quietest mark — a lighter rotation
    // and lower ink density than the other three, so an absence of
    // evidence doesn't compete visually with an actual determination.
    final rotation = kind == VerdictKind.notExamined ? -6.0 : -7.5;
    final fillAlpha = kind == VerdictKind.notExamined ? 0.05 : 0.09;

    return Transform.rotate(
      angle: rotation * 3.14159265 / 180,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: horizontalPad,
          vertical: verticalPad,
        ),
        decoration: BoxDecoration(
          color: color.withValues(alpha: fillAlpha),
          borderRadius: BorderRadius.circular(2),
          // Double border is the "ink bleed" cue: a slightly softer outer
          // line and a crisper inner one, the way a real stamp's edge
          // isn't a single clean stroke.
          border: Border.all(color: color.withValues(alpha: 0.55), width: 1.5),
        ),
        foregroundDecoration: BoxDecoration(
          borderRadius: BorderRadius.circular(2),
          border: Border.all(color: color.withValues(alpha: 0.9), width: 0.75),
        ),
        child: Text(kind.label, style: textStyle),
      ),
    );
  }
}
