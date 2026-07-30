/// Layout, motion, and numeric-type tokens that sit alongside the colour and
/// spacing tokens in `core/design/app_theme.dart`.
///
/// ## Why numerals get their own tokens
///
/// This app is read, not skimmed. A reviewer compares 96.4 against 94.8, scans
/// a column of contribution weights, checks whether a probability moved. In a
/// proportional font the digits have different widths, so those columns wobble
/// and the eye has to re-find the decimal point on every row. Tabular figures
/// fix the advance width so digits line up in a column and, crucially, so a
/// number that updates in place does not make the layout twitch.
///
/// This is the single detail that most separates a credible data tool from a
/// styled form, and it costs one font feature. Every number the user might
/// compare against another number should use [AppTypeX.numeric] or
/// [AppTypeX.numericStrong].
library;

import 'package:flutter/material.dart';

/// Window-width breakpoints.
///
/// Named for what changes at each, not for devices — this app runs in a
/// resizable desktop window far more often than on a phone, and "tablet" would
/// describe none of the real cases.
abstract final class Breakpoints {
  /// Below this the navigation moves to the bottom of the screen and every
  /// multi-column layout collapses to one column.
  static const double compact = 700;

  /// At or above this the navigation rail shows its labels rather than icons
  /// alone, and detail screens may use two columns.
  static const double expanded = 1080;

  static bool isCompact(BuildContext context) =>
      MediaQuery.sizeOf(context).width < compact;

  static bool isExpanded(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= expanded;
}

/// Content measures. Long-form prose is capped near 70 characters because that
/// is where reading speed peaks; data surfaces are allowed to run wider because
/// a table gains nothing from being narrow.
abstract final class Measures {
  static const double prose = 680;
  static const double form = 720;
  static const double workspace = 1240;
}

/// Motion. Short and consistent — an audit tool should feel immediate, and a
/// long transition on a data view reads as lag, not as polish.
abstract final class Motion {
  static const Duration fast = Duration(milliseconds: 120);
  static const Duration normal = Duration(milliseconds: 200);
  static const Curve curve = Curves.easeOutCubic;
}

const List<FontFeature> _tabularFeatures = [
  FontFeature.tabularFigures(),
  // Slashed zero: in a column of identity-similarity scores, a zero and an
  // O should never be a judgement call.
  FontFeature.slashedZero(),
];

/// Applies tabular figures to any existing style.
///
/// Use this when a style is already established and only its digits need
/// fixing — most importantly on a **live-updating** figure, where proportional
/// digits make the text visibly twitch as the value changes.
extension TabularFiguresX on TextStyle {
  TextStyle get tabular => copyWith(fontFeatures: _tabularFeatures);
}

/// Numeric type styles, derived from the theme so they inherit colour and
/// scale rather than hardcoding either.
extension AppTypeX on BuildContext {
  static const List<FontFeature> _tabular = _tabularFeatures;

  /// Body-sized figures that align in a column.
  TextStyle get numeric =>
      (Theme.of(this).textTheme.bodyMedium ?? const TextStyle())
          .copyWith(fontFeatures: _tabular);

  /// The same, at label weight — for a figure that is the point of its row.
  TextStyle get numericStrong =>
      (Theme.of(this).textTheme.labelLarge ?? const TextStyle())
          .copyWith(fontFeatures: _tabular);

  /// A headline figure, e.g. the single number a card exists to report.
  TextStyle get numericDisplay =>
      (Theme.of(this).textTheme.headlineSmall ?? const TextStyle())
          .copyWith(fontFeatures: _tabular, letterSpacing: -0.4);
}
