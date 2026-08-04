/// The larger composite surfaces the Golden Taupe screens are assembled from.
///
/// ## Why this is a second file and not more of `components.dart`
///
/// `components.dart` holds the small primitives — a titled card, a stat, a
/// label/value row. Everything here is a *pattern*: a metric strip, a funnel, a
/// transcript turn, a radar. They are bigger, they own a paint routine or a
/// layout decision, and several of them exist to serve one screen shape from the
/// design mockups. Keeping them apart means the primitive layer stays small
/// enough to hold in your head, which is the only reason it gets reused.
///
/// ## The rule every widget in this file obeys
///
/// **No widget here invents a number.** Each takes its values as arguments and
/// renders exactly what it is given. That sounds obvious; it is written down
/// because the mockups these are derived from are full of figures with nothing
/// behind them — an "88/100 Hiring Score", a "99.4% AI Accuracy", a candidate
/// leaderboard ranked by unexplained points. A component that defaulted a value,
/// or filled a gap with a plausible-looking one, would launder those back in.
/// Where a caller has nothing to show, these render an explicit absence: see
/// [MetricCard.unavailable] and [RingGauge]'s null [RingGauge.fraction].
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/design/app_theme.dart';
import 'tokens.dart';

// ---------------------------------------------------------------------------
// Metrics
// ---------------------------------------------------------------------------

/// One headline figure in the dashboard's metric strip.
///
/// The [qualifier] is not optional decoration — in this app a figure almost
/// always needs a denominator or a caveat ("of 5 measured", "across 3 sessions")
/// and a number shown without one is the thing this product exists to argue
/// against. [unavailable] is the honest rendering when the underlying quantity
/// could not be computed: it shows a dash and says why, rather than a zero that
/// reads as a real measurement of nothing.
class MetricCard extends StatelessWidget {
  const MetricCard({
    super.key,
    required this.label,
    required this.value,
    this.unit,
    this.qualifier,
    this.icon,
    this.badge,
    this.fraction,
    this.emphasised = false,
    this.tone,
    this.onTap,
  }) : unavailableReason = null;

  /// A figure that genuinely has no value right now.
  const MetricCard.unavailable({
    super.key,
    required this.label,
    required String reason,
    this.icon,
    this.onTap,
  })  : value = '—',
        unit = null,
        qualifier = reason,
        badge = null,
        fraction = null,
        emphasised = false,
        tone = null,
        unavailableReason = reason;

  final String label;
  final String value;

  /// Rendered smaller and after [value] — "/100", "%", "wpm". Kept separate so
  /// the figure and its unit do not share one font size, which is what makes a
  /// row of these scan as a column of numbers.
  final String? unit;

  final String? qualifier;
  final IconData? icon;

  /// A short status word in the card's top-right — "LIVE", "3 open".
  final String? badge;

  /// When non-null, draws a thin proportion rule under the figure. Only pass
  /// this when the figure really is a fraction of a known whole.
  final double? fraction;

  /// Gives this card the gold-tinted treatment. At most one card in a strip
  /// should use it, or the emphasis means nothing.
  final bool emphasised;

  final Color? tone;
  final VoidCallback? onTap;
  final String? unavailableReason;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final brand = context.brand;
    final muted = unavailableReason != null;

    final body = Padding(
      padding: const EdgeInsets.all(Spacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              if (icon != null)
                Icon(
                  icon,
                  size: 18,
                  color: emphasised ? brand.accent : scheme.onSurfaceVariant,
                ),
              const Spacer(),
              if (badge != null) _Badge(text: badge!, emphasised: emphasised),
            ],
          ),
          const SizedBox(height: Spacing.md),
          Text(
            label.toUpperCase(),
            style: theme.textTheme.labelSmall,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: Spacing.sm),
          // Baseline-aligned so the unit sits on the figure's baseline rather
          // than floating at the top of its line box.
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Flexible(
                child: Text(
                  value,
                  style: context.numericDisplay.copyWith(
                    fontSize: 28,
                    fontWeight: FontWeight.w700,
                    color: muted
                        ? scheme.onSurfaceVariant
                        : (tone ?? scheme.onSurface),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (unit != null) ...[
                const SizedBox(width: 2),
                Text(
                  unit!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ],
          ),
          if (fraction != null) ...[
            const SizedBox(height: Spacing.sm),
            _Rule(fraction: fraction!, colour: tone ?? brand.accent),
          ],
          if (qualifier != null) ...[
            const SizedBox(height: Spacing.sm),
            Text(
              qualifier!,
              style: theme.textTheme.bodySmall,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );

    return Card(
      color: emphasised ? brand.accentSoft : null,
      shape: emphasised
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(Radii.surface),
              side: BorderSide(color: brand.accent.withValues(alpha: 0.55)),
            )
          : null,
      child: onTap == null
          ? body
          : InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(Radii.surface),
              child: body,
            ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.text, this.emphasised = false});

  final String text;
  final bool emphasised;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colour =
        emphasised ? context.brand.accent : theme.colorScheme.onSurfaceVariant;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Spacing.sm, vertical: 2),
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      child: Text(
        text.toUpperCase(),
        style: theme.textTheme.labelSmall?.copyWith(
          color: colour,
          fontSize: 10,
        ),
      ),
    );
  }
}

/// A thin proportion rule. Deliberately not a [LinearProgressIndicator]: this
/// annotates a figure that is already on screen, so it carries no label of its
/// own and must not be the only place the value appears.
class _Rule extends StatelessWidget {
  const _Rule({required this.fraction, required this.colour});

  final double fraction;
  final Color colour;

  @override
  Widget build(BuildContext context) {
    final clamped = fraction.isNaN ? 0.0 : fraction.clamp(0.0, 1.0);

    return ClipRRect(
      borderRadius: BorderRadius.circular(Radii.pill),
      child: LinearProgressIndicator(
        value: clamped,
        minHeight: 4,
        backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
        valueColor: AlwaysStoppedAnimation<Color>(colour),
      ),
    );
  }
}

/// Lays metric cards out in a strip that wraps rather than shrinking.
///
/// Cards keep a floor width so a six-metric strip on a narrow window becomes
/// two rows of three rather than six unreadable slivers — the mockup's single
/// row is a wide-window case, not a requirement.
class MetricStrip extends StatelessWidget {
  const MetricStrip({
    super.key,
    required this.children,
    this.minCardWidth = 168,
    this.spacing = Spacing.md,
  });

  final List<Widget> children;
  final double minCardWidth;
  final double spacing;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxWidth;
        final columns = ((available + spacing) / (minCardWidth + spacing))
            .floor()
            .clamp(1, children.length);
        final width = (available - spacing * (columns - 1)) / columns;

        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [
            for (final child in children) SizedBox(width: width, child: child),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Funnel
// ---------------------------------------------------------------------------

/// One stage of a stage-to-stage funnel: what the stage is, how many reached it,
/// and how that compares to the first stage.
///
/// The count is always shown as an absolute number *and* as a share of the top
/// of the funnel, because a percentage alone hides the sample size — "50%" over
/// two claims and over two hundred are different facts.
class FunnelStage {
  const FunnelStage({
    required this.label,
    required this.count,
    required this.explanation,
  });

  final String label;
  final int count;

  /// What reaching this stage actually means, in terms of something that
  /// happened. Shown on hover/long-press so the funnel cannot become a set of
  /// bars whose meaning lives only in the reader's assumption.
  final String explanation;
}

class FunnelChart extends StatelessWidget {
  const FunnelChart({super.key, required this.stages});

  final List<FunnelStage> stages;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final brand = context.brand;

    if (stages.isEmpty) {
      return Text(
        'Nothing to plot yet.',
        style: theme.textTheme.bodySmall,
      );
    }

    final top = stages.first.count;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < stages.length; i++) ...[
          if (i > 0) const SizedBox(height: Spacing.lg),
          Tooltip(
            message: stages[i].explanation,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        stages[i].label,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                    const SizedBox(width: Spacing.sm),
                    Text(
                      top == 0 || i == 0
                          ? '${stages[i].count}'
                          : '${stages[i].count} of $top',
                      style: context.numericStrong.copyWith(
                        color: i == 0 ? null : brand.accent,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: Spacing.sm),
                _FunnelBar(
                  fraction: top == 0 ? 0 : stages[i].count / top,
                  colour: brand.accent,
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// A funnel bar with the mockup's leading-edge marker: a filled track plus a
/// solid 2px tick at the fill's end, which is what makes a short bar readable
/// at all. A 2.5% bar with no marker is indistinguishable from an empty one.
class _FunnelBar extends StatelessWidget {
  const _FunnelBar({required this.fraction, required this.colour});

  final double fraction;
  final Color colour;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final clamped = fraction.isNaN ? 0.0 : fraction.clamp(0.0, 1.0);

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return Container(
          height: 28,
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(Radii.control),
          ),
          child: Stack(
            children: [
              Container(
                width: width * clamped,
                decoration: BoxDecoration(
                  color: colour.withValues(alpha: 0.28),
                  borderRadius: BorderRadius.circular(Radii.control),
                ),
              ),
              Positioned(
                // Kept inside the track at both extremes, so a full bar's
                // marker is not clipped and an empty one still shows a zero
                // mark rather than nothing at all.
                left: (width * clamped).clamp(0.0, width - 2),
                top: 0,
                bottom: 0,
                child: Container(width: 2, color: colour),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Gauges
// ---------------------------------------------------------------------------

/// A ring gauge for a single proportion, with the figure in the middle.
///
/// [fraction] is nullable and that is the important part of this widget. A
/// proportion with no denominator — no checks attempted, no claims examined —
/// has no value, and the honest render is an empty ring with a dash, not a full
/// ring (which would read as 100%) or an empty one (which would read as 0%).
class RingGauge extends StatelessWidget {
  const RingGauge({
    super.key,
    required this.fraction,
    required this.caption,
    this.centreLabel,
    this.diameter = 132,
    this.tone,
    this.unavailableNote = 'not measured',
  });

  final double? fraction;

  /// The word under the figure — "verified", "grounded", "examined".
  final String caption;

  /// Overrides the derived percentage in the centre. Use when the meaningful
  /// figure is a count ("14 of 16") rather than a percentage.
  final String? centreLabel;

  final double diameter;
  final Color? tone;
  final String unavailableNote;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colour = tone ?? context.brand.accent;
    final value = fraction;
    final known = value != null && !value.isNaN;
    final clamped = known ? value.clamp(0.0, 1.0) : 0.0;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: diameter,
          height: diameter,
          child: Stack(
            alignment: Alignment.center,
            children: [
              CustomPaint(
                size: Size.square(diameter),
                painter: _RingPainter(
                  fraction: clamped,
                  colour: known ? colour : scheme.outlineVariant,
                  track: scheme.surfaceContainerHighest,
                  stroke: diameter / 12,
                ),
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    known
                        ? (centreLabel ?? '${(clamped * 100).round()}')
                        : '—',
                    style: context.numericDisplay.copyWith(
                      fontSize: diameter / 4.2,
                      fontWeight: FontWeight.w700,
                      color: known ? scheme.onSurface : scheme.onSurfaceVariant,
                    ),
                  ),
                  Text(
                    (known ? caption : unavailableNote).toUpperCase(),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.labelSmall?.copyWith(fontSize: 9),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _RingPainter extends CustomPainter {
  const _RingPainter({
    required this.fraction,
    required this.colour,
    required this.track,
    required this.stroke,
  });

  final double fraction;
  final Color colour;
  final Color track;
  final double stroke;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(0, 0, size.width, size.height)
        .deflate(stroke / 2);

    final base = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = track;
    canvas.drawArc(rect, 0, math.pi * 2, false, base);

    if (fraction <= 0) return;

    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = colour;
    // From twelve o'clock, clockwise — the direction every reader expects.
    canvas.drawArc(rect, -math.pi / 2, math.pi * 2 * fraction, false, arc);
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.fraction != fraction ||
      old.colour != colour ||
      old.track != track ||
      old.stroke != stroke;
}

/// One axis of a [RadarChart].
class RadarAxis {
  const RadarAxis({
    required this.label,
    required this.fraction,
    required this.detail,
  });

  final String label;

  /// 0–1. The caller is responsible for this being a real ratio of real counts.
  final double fraction;

  /// The counts behind [fraction], shown in the legend beneath the chart. A
  /// radar with no numbers next to it is a shape, not a measurement.
  final String detail;
}

/// A radar plot over three or more axes.
///
/// Every axis is labelled and every value is also printed as text below, for
/// two reasons: a polygon's area is easy to misread, and a screen reader gets
/// nothing at all from a [CustomPaint].
class RadarChart extends StatelessWidget {
  const RadarChart({super.key, required this.axes, this.size = 200});

  final List<RadarAxis> axes;
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (axes.length < 3) {
      return Text(
        axes.isEmpty
            ? 'No skills tagged on this session\'s claims, so there is nothing '
                'to plot.'
            : 'A radar needs at least three axes; this session has '
                '${axes.length}. The figures are listed below instead.',
        style: theme.textTheme.bodySmall,
      );
    }

    return Column(
      children: [
        Center(
          child: Semantics(
            label: 'Coverage by skill: '
                '${axes.map((a) => '${a.label}, ${a.detail}').join('; ')}',
            child: CustomPaint(
              size: Size.square(size),
              painter: _RadarPainter(
                axes: axes,
                grid: theme.colorScheme.outlineVariant,
                fill: context.brand.accent,
                labelStyle: theme.textTheme.labelSmall ?? const TextStyle(),
              ),
            ),
          ),
        ),
        const SizedBox(height: Spacing.lg),
        for (final axis in axes)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Row(
              children: [
                Expanded(
                  child: Text(axis.label, style: theme.textTheme.bodySmall),
                ),
                Text(axis.detail, style: context.numeric),
              ],
            ),
          ),
      ],
    );
  }
}

class _RadarPainter extends CustomPainter {
  _RadarPainter({
    required this.axes,
    required this.grid,
    required this.fill,
    required this.labelStyle,
  });

  final List<RadarAxis> axes;
  final Color grid;
  final Color fill;
  final TextStyle labelStyle;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = Offset(size.width / 2, size.height / 2);
    // Leaves room for the axis labels drawn outside the outer ring.
    final radius = math.min(size.width, size.height) / 2 - 24;
    final step = math.pi * 2 / axes.length;

    Offset at(int i, double r) {
      final angle = -math.pi / 2 + step * i;
      return centre + Offset(math.cos(angle) * r, math.sin(angle) * r);
    }

    final gridPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = grid;

    // Three concentric rings at 1/3, 2/3, 1 — enough to judge a value against
    // without turning the plot into graph paper.
    for (final scale in const [0.33, 0.66, 1.0]) {
      final path = Path();
      for (var i = 0; i < axes.length; i++) {
        final p = at(i, radius * scale);
        i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(path..close(), gridPaint);
    }

    for (var i = 0; i < axes.length; i++) {
      canvas.drawLine(centre, at(i, radius), gridPaint);
    }

    final shape = Path();
    for (var i = 0; i < axes.length; i++) {
      final f = axes[i].fraction.isNaN ? 0.0 : axes[i].fraction.clamp(0.0, 1.0);
      final p = at(i, radius * f);
      i == 0 ? shape.moveTo(p.dx, p.dy) : shape.lineTo(p.dx, p.dy);
    }
    shape.close();

    canvas.drawPath(
      shape,
      Paint()
        ..style = PaintingStyle.fill
        ..color = fill.withValues(alpha: 0.28),
    );
    canvas.drawPath(
      shape,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = fill,
    );

    for (var i = 0; i < axes.length; i++) {
      final painter = TextPainter(
        text: TextSpan(text: axes[i].label, style: labelStyle),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: 76);

      final anchor = at(i, radius + 14);
      canvas.drawParagraphAt(painter, anchor, centre);
    }
  }

  @override
  bool shouldRepaint(_RadarPainter old) => true;
}

extension on Canvas {
  /// Places a label just outside the plot, nudged so it sits away from the
  /// centre on both axes rather than being centred on the anchor and overlapping
  /// the outer ring.
  void drawParagraphAt(TextPainter painter, Offset anchor, Offset centre) {
    final dx = anchor.dx < centre.dx
        ? -painter.width
        : (anchor.dx > centre.dx ? 0.0 : -painter.width / 2);
    final dy = anchor.dy < centre.dy
        ? -painter.height
        : (anchor.dy > centre.dy ? 0.0 : -painter.height / 2);
    painter.paint(this, anchor + Offset(dx, dy));
  }
}

// ---------------------------------------------------------------------------
// Small parts
// ---------------------------------------------------------------------------

/// A pill tag. Never tappable — the brief reserves pills for status and skill
/// labels precisely so they are visually distinct from buttons.
class Tag extends StatelessWidget {
  const Tag({super.key, required this.label, this.tone, this.icon});

  final String label;
  final Color? tone;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colour = tone ?? theme.colorScheme.onSurfaceVariant;

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.md,
        vertical: Spacing.xs + 1,
      ),
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(Radii.pill),
        border: Border.all(color: colour.withValues(alpha: 0.28)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: colour),
            const SizedBox(width: Spacing.xs),
          ],
          Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(color: colour),
          ),
        ],
      ),
    );
  }
}

/// A circular monogram. Used wherever the mockups use a photograph.
///
/// There are no candidate photographs in this product and there will not be:
/// storing a face image for display is a different and much larger privacy
/// commitment than holding a face *embedding* for the length of one session,
/// which is all the verification path does. Initials carry the identifying
/// function the avatar had in the mockup without that.
class Monogram extends StatelessWidget {
  const Monogram({super.key, required this.name, this.diameter = 40, this.tone});

  final String name;
  final double diameter;
  final Color? tone;

  static String initialsOf(String name) {
    final words = name
        .trim()
        .split(RegExp(r'[\s\-—·]+'))
        .where((w) => w.isNotEmpty && RegExp(r'[A-Za-z0-9]').hasMatch(w))
        .toList();
    if (words.isEmpty) return '?';
    if (words.length == 1) {
      return words.first.substring(0, math.min(2, words.first.length))
          .toUpperCase();
    }
    return (words[0][0] + words[1][0]).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colour = tone ?? theme.colorScheme.secondary;

    return Container(
      width: diameter,
      height: diameter,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.16),
        shape: BoxShape.circle,
        border: Border.all(color: colour.withValues(alpha: 0.3)),
      ),
      child: Text(
        initialsOf(name),
        style: theme.textTheme.labelMedium?.copyWith(
          color: colour,
          fontSize: diameter / 3,
        ),
      ),
    );
  }
}

/// One entry in a vertical timeline: a dot on a rule, then the content.
///
/// [isLast] suppresses the connecting rule so the timeline ends rather than
/// trailing into whitespace.
class TimelineEntry extends StatelessWidget {
  const TimelineEntry({
    super.key,
    required this.title,
    required this.meta,
    required this.body,
    this.isLast = false,
    this.tone,
  });

  final String title;
  final String meta;
  final String body;
  final bool isLast;
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colour = tone ?? context.brand.accent;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 20,
          child: Column(
            children: [
              const SizedBox(height: 4),
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(color: colour, shape: BoxShape.circle),
              ),
              if (!isLast)
                Expanded(
                  child: Container(
                    width: 1,
                    margin: const EdgeInsets.symmetric(vertical: Spacing.xs),
                    color: theme.colorScheme.outlineVariant,
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(width: Spacing.md),
        Expanded(
          child: Padding(
            padding: EdgeInsets.only(bottom: isLast ? 0 : Spacing.xl),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Wrap, not Row: a long title and a long timestamp on a narrow
                // window need to fall onto two lines, not compete for one.
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: Spacing.sm,
                  children: [
                    Text(title, style: theme.textTheme.titleSmall),
                    Text(meta, style: context.numeric.copyWith(
                      color: theme.textTheme.bodySmall?.color,
                    )),
                  ],
                ),
                if (body.isNotEmpty) ...[
                  const SizedBox(height: Spacing.xs),
                  Text(body, style: theme.textTheme.bodyMedium),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// A labelled horizontal meter — the mockup's "Technical Stack" rows.
///
/// [level] is a word, not a number, and it comes from the caller. This widget
/// will not turn a count into a grade like "Advanced": inventing a proficiency
/// band from an evidence count is exactly the kind of unearned judgement this
/// product refuses to make.
class SkillMeter extends StatelessWidget {
  const SkillMeter({
    super.key,
    required this.skill,
    required this.level,
    required this.fraction,
    this.tone,
  });

  final String skill;
  final String level;
  final double fraction;
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colour = tone ?? context.brand.accent;

    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  skill,
                  style: theme.textTheme.titleSmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: Spacing.sm),
              Text(
                level,
                style: theme.textTheme.bodySmall?.copyWith(color: colour),
              ),
            ],
          ),
          const SizedBox(height: Spacing.sm),
          _Rule(fraction: fraction, colour: colour),
        ],
      ),
    );
  }
}

/// A segmented stage indicator — "STAGE 3 OF 5", with a bar per stage.
class StageProgress extends StatelessWidget {
  const StageProgress({
    super.key,
    required this.stageIndex,
    required this.stageCount,
    required this.stageName,
  });

  /// 0-based.
  final int stageIndex;
  final int stageCount;
  final String stageName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final brand = context.brand;
    final total = math.max(stageCount, 1);
    final done = stageIndex.clamp(0, total);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'STAGE ${done + 1} OF $total: ${stageName.toUpperCase()}',
                style: theme.textTheme.labelSmall,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: Spacing.sm),
            Text(
              '${((done) / total * 100).round()}% done',
              style: theme.textTheme.labelSmall?.copyWith(color: brand.accent),
            ),
          ],
        ),
        const SizedBox(height: Spacing.sm),
        Row(
          children: [
            for (var i = 0; i < total; i++) ...[
              if (i > 0) const SizedBox(width: Spacing.xs),
              Expanded(
                child: Container(
                  height: 4,
                  decoration: BoxDecoration(
                    color: i < done
                        ? brand.accent
                        : (i == done
                            ? brand.accent.withValues(alpha: 0.4)
                            : theme.colorScheme.surfaceContainerHighest),
                    borderRadius: BorderRadius.circular(Radii.pill),
                  ),
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

/// One turn in a transcript: who spoke, what they said, and any tags attached.
class TranscriptTurn extends StatelessWidget {
  const TranscriptTurn({
    super.key,
    required this.speaker,
    required this.text,
    this.isSystem = false,
    this.tags = const [],
    this.at,
  });

  final String speaker;
  final String text;

  /// System turns get the gold monogram and upright text; the person's turns are
  /// italic and quoted, so a reader scanning the column can always tell which
  /// words came from the candidate.
  final bool isSystem;

  final List<String> tags;
  final DateTime? at;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final brand = context.brand;

    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.xl),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 32,
            height: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: isSystem
                  ? brand.accent.withValues(alpha: 0.18)
                  : scheme.surfaceContainerHighest,
              shape: BoxShape.circle,
            ),
            child: Icon(
              isSystem ? Icons.hub_outlined : Icons.person_outline,
              size: 16,
              color: isSystem ? brand.accent : scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: Spacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        speaker.toUpperCase(),
                        style: theme.textTheme.labelSmall,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (at != null)
                      Text(
                        _clock(at!),
                        style: context.numeric.copyWith(
                          color: theme.textTheme.bodySmall?.color,
                          fontSize: 11,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: Spacing.sm),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(Spacing.md),
                  decoration: BoxDecoration(
                    color: isSystem ? brand.cream : scheme.surface,
                    borderRadius: BorderRadius.circular(Radii.control),
                    border: Border.all(color: scheme.outlineVariant),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isSystem ? text : '"$text"',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontStyle:
                              isSystem ? FontStyle.normal : FontStyle.italic,
                        ),
                      ),
                      if (tags.isNotEmpty) ...[
                        const SizedBox(height: Spacing.md),
                        Wrap(
                          spacing: Spacing.sm,
                          runSpacing: Spacing.sm,
                          children: [
                            for (final tag in tags) Tag(label: tag),
                          ],
                        ),
                      ],
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

  static String _clock(DateTime t) {
    final l = t.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(l.hour)}:${two(l.minute)}:${two(l.second)}';
  }
}

/// A dashed drop target for file ingest.
///
/// Tappable across its whole area, and it states the accepted formats and the
/// size ceiling up front rather than rejecting a file after the user has chosen
/// it.
class DropZone extends StatelessWidget {
  const DropZone({
    super.key,
    required this.headline,
    required this.detail,
    required this.onTap,
    this.capabilities = const [],
    this.icon = Icons.upload_file_outlined,
    this.busy = false,
  });

  final String headline;
  final String detail;
  final VoidCallback onTap;

  /// Short statements of what ingest will actually do. Each must correspond to
  /// something the code performs.
  final List<String> capabilities;

  final IconData icon;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final brand = context.brand;

    return InkWell(
      onTap: busy ? null : onTap,
      borderRadius: BorderRadius.circular(Radii.surface),
      child: CustomPaint(
        painter: _DashedBorderPainter(
          colour: brand.accent.withValues(alpha: 0.55),
          radius: Radii.surface,
        ),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(
            horizontal: Spacing.xl,
            vertical: Spacing.xxxl,
          ),
          child: Column(
            children: [
              Container(
                width: 56,
                height: 56,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: brand.accent.withValues(alpha: 0.16),
                  shape: BoxShape.circle,
                ),
                child: busy
                    ? SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: brand.accent,
                        ),
                      )
                    : Icon(icon, size: 24, color: brand.accent),
              ),
              const SizedBox(height: Spacing.lg),
              Text(
                headline,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleLarge,
              ),
              const SizedBox(height: Spacing.xs),
              Text(
                detail,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
              ),
              if (capabilities.isNotEmpty) ...[
                const SizedBox(height: Spacing.lg),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: Spacing.sm,
                  runSpacing: Spacing.sm,
                  children: [
                    for (final c in capabilities) Tag(label: c),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _DashedBorderPainter extends CustomPainter {
  const _DashedBorderPainter({required this.colour, required this.radius});

  final Color colour;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..color = colour;

    final path = Path()
      ..addRRect(RRect.fromRectAndRadius(
        Rect.fromLTWH(0, 0, size.width, size.height).deflate(0.7),
        Radius.circular(radius),
      ));

    // Walk the path in 7-on/5-off steps. Flutter has no dashed stroke, and
    // faking one with a container border produces a solid line.
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final end = math.min(distance + 7, metric.length);
        canvas.drawPath(metric.extractPath(distance, end), paint);
        distance = end + 5;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorderPainter old) =>
      old.colour != colour || old.radius != radius;
}

/// A compact bar series — one bar per sample, no axis.
///
/// Carries a [caption] stating what the bars are and over what window, because
/// a bare sparkline invites the reader to infer a trend that the underlying
/// sample size may not support.
class SparkBars extends StatelessWidget {
  const SparkBars({
    super.key,
    required this.samples,
    required this.caption,
    this.height = 44,
    this.tone,
  });

  final List<double> samples;
  final String caption;
  final double height;
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colour = tone ?? context.brand.accent;

    if (samples.isEmpty) {
      return Text(
        '$caption — no samples recorded.',
        style: theme.textTheme.bodySmall,
      );
    }

    final peak = samples.reduce(math.max);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: height,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (var i = 0; i < samples.length; i++) ...[
                if (i > 0) const SizedBox(width: 2),
                Expanded(
                  child: Container(
                    // A zero sample still gets 2px so the reader can see a
                    // sample was taken and was zero, not that none was taken.
                    height: peak <= 0
                        ? 2
                        : math.max(2, (samples[i] / peak) * height),
                    decoration: BoxDecoration(
                      color: colour.withValues(alpha: 0.55),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: Spacing.sm),
        Text(caption, style: theme.textTheme.bodySmall),
      ],
    );
  }
}

/// A row in a list of things you can open — the mockup's "upcoming interviews"
/// and "recent activity" rows.
class RecordRow extends StatelessWidget {
  const RecordRow({
    super.key,
    required this.title,
    required this.subtitle,
    this.leading,
    this.trailing,
    this.onTap,
  });

  final String title;
  final String subtitle;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final content = Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.md,
        vertical: Spacing.md,
      ),
      child: Row(
        children: [
          if (leading != null) ...[leading!, const SizedBox(width: Spacing.md)],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleSmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: theme.textTheme.bodySmall,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: Spacing.sm),
            trailing!,
          ],
        ],
      ),
    );

    return Container(
      margin: const EdgeInsets.only(bottom: Spacing.sm),
      decoration: BoxDecoration(
        color: context.brand.cream,
        borderRadius: BorderRadius.circular(Radii.control),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: onTap == null
          ? content
          : InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(Radii.control),
              child: content,
            ),
    );
  }
}

/// A page-level region: a heading, an optional trailing action, then content —
/// with the brief's 48px rhythm between regions applied by the page, not here.
class PageSection extends StatelessWidget {
  const PageSection({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: theme.textTheme.titleLarge),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(subtitle!, style: theme.textTheme.bodySmall),
                  ],
                ],
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: Spacing.md),
              trailing!,
            ],
          ],
        ),
        const SizedBox(height: Spacing.lg),
        child,
      ],
    );
  }
}
