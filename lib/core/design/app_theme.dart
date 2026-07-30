/// The app's design system: colour tokens, type scale, and component themes.
///
/// ## Why navy and not the original indigo
///
/// The first build seeded Material 3 from `0xFF4F46E5` — an indigo-violet that
/// reads as "AI startup". That is precisely the wrong signal for this product.
/// CogniHire's whole argument is that it is *not* another AI interview tool: it
/// is an evidence record a reviewer is meant to trust and, if challenged,
/// defend. Audit, compliance, and verification products earn that read with
/// deep neutrals and a single restrained accent — not a violet gradient.
///
/// So: slate navy as the primary, a sober sky-blue for actions, and warm-free
/// neutrals with a slight blue bias so greys read as chosen rather than
/// defaulted.
///
/// ## Evidence colours are a separate axis from the accent
///
/// [EvidenceColors] below is deliberately not derived from the brand hue.
/// Verified / disputed / unmeasured are *semantic state*, and they have to stay
/// legible and unambiguous regardless of what the brand accent is. Mixing them
/// into the seed would mean a future brand tweak silently changing what
/// "disputed" looks like.
///
/// **Note what is absent:** there is no "score", "grade", or "rating" colour
/// ramp anywhere in this file — no red→amber→green gradient a reviewer could
/// read as an aggregate quality scale. That would be a composite score
/// expressed in colour, and this product does not have one.
library;

import 'package:flutter/material.dart';

/// Spacing scale. 4pt rhythm — every gap in the app should come from here
/// rather than an arbitrary literal, which is most of what separates a
/// polished layout from a nearly-polished one.
abstract final class Spacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
  static const double xxxl = 48;
}

/// Corner radii. Two values, used consistently, rather than a different
/// rounding on every surface.
abstract final class Radii {
  static const double control = 8;
  static const double surface = 12;
  static const double pill = 999;
}

/// Semantic colours for evidence state.
///
/// Each has a light and dark variant chosen for contrast against its own
/// theme's surface, not naively inverted.
class EvidenceColors extends ThemeExtension<EvidenceColors> {
  const EvidenceColors({
    required this.verified,
    required this.verifiedContainer,
    required this.disputed,
    required this.disputedContainer,
    required this.unmeasured,
    required this.unmeasuredContainer,
    required this.notExamined,
    required this.notExaminedContainer,
  });

  /// A real comparison ran and cleared the threshold.
  final Color verified;
  final Color verifiedContainer;

  /// A real comparison ran and did not clear it.
  final Color disputed;
  final Color disputedContainer;

  /// Nothing could be measured. Visually distinct from both of the above —
  /// never a paler green, which would read as "nearly verified".
  final Color unmeasured;
  final Color unmeasuredContainer;

  /// Never examined. Deliberately the quietest of the four: absence of
  /// evidence should look like absence, not like a soft failure.
  final Color notExamined;
  final Color notExaminedContainer;

  static const light = EvidenceColors(
    verified: Color(0xFF15803D),
    verifiedContainer: Color(0xFFDCFCE7),
    disputed: Color(0xFFB91C1C),
    disputedContainer: Color(0xFFFEE2E2),
    unmeasured: Color(0xFFB45309),
    unmeasuredContainer: Color(0xFFFEF3C7),
    notExamined: Color(0xFF64748B),
    notExaminedContainer: Color(0xFFF1F5F9),
  );

  static const dark = EvidenceColors(
    verified: Color(0xFF4ADE80),
    verifiedContainer: Color(0xFF14532D),
    disputed: Color(0xFFF87171),
    disputedContainer: Color(0xFF7F1D1D),
    unmeasured: Color(0xFFFBBF24),
    unmeasuredContainer: Color(0xFF78350F),
    notExamined: Color(0xFF94A3B8),
    notExaminedContainer: Color(0xFF1E293B),
  );

  @override
  EvidenceColors copyWith({
    Color? verified,
    Color? verifiedContainer,
    Color? disputed,
    Color? disputedContainer,
    Color? unmeasured,
    Color? unmeasuredContainer,
    Color? notExamined,
    Color? notExaminedContainer,
  }) =>
      EvidenceColors(
        verified: verified ?? this.verified,
        verifiedContainer: verifiedContainer ?? this.verifiedContainer,
        disputed: disputed ?? this.disputed,
        disputedContainer: disputedContainer ?? this.disputedContainer,
        unmeasured: unmeasured ?? this.unmeasured,
        unmeasuredContainer: unmeasuredContainer ?? this.unmeasuredContainer,
        notExamined: notExamined ?? this.notExamined,
        notExaminedContainer: notExaminedContainer ?? this.notExaminedContainer,
      );

  @override
  EvidenceColors lerp(ThemeExtension<EvidenceColors>? other, double t) {
    if (other is! EvidenceColors) return this;
    return EvidenceColors(
      verified: Color.lerp(verified, other.verified, t)!,
      verifiedContainer:
          Color.lerp(verifiedContainer, other.verifiedContainer, t)!,
      disputed: Color.lerp(disputed, other.disputed, t)!,
      disputedContainer:
          Color.lerp(disputedContainer, other.disputedContainer, t)!,
      unmeasured: Color.lerp(unmeasured, other.unmeasured, t)!,
      unmeasuredContainer:
          Color.lerp(unmeasuredContainer, other.unmeasuredContainer, t)!,
      notExamined: Color.lerp(notExamined, other.notExamined, t)!,
      notExaminedContainer:
          Color.lerp(notExaminedContainer, other.notExaminedContainer, t)!,
    );
  }
}

/// Convenience accessor so screens read `context.evidence.verified` rather
/// than reaching for a hardcoded `Colors.green.shade700`.
extension EvidenceColorsX on BuildContext {
  EvidenceColors get evidence =>
      Theme.of(this).extension<EvidenceColors>() ?? EvidenceColors.light;
}

abstract final class AppTheme {
  // Trust & Authority palette — deep slate navy, sober sky accent.
  static const _navy = Color(0xFF0F172A);
  static const _accent = Color(0xFF0369A1);
  static const _accentDark = Color(0xFF38BDF8);

  static ThemeData get light {
    final scheme = ColorScheme.fromSeed(
      seedColor: _navy,
      brightness: Brightness.light,
    ).copyWith(
      primary: _navy,
      onPrimary: Colors.white,
      secondary: const Color(0xFF334155),
      tertiary: _accent,
      surface: const Color(0xFFFCFDFE),
      // Slight blue bias rather than a pure neutral, so the greys read as
      // chosen rather than inherited.
      surfaceContainerHighest: const Color(0xFFEEF2F6),
      outlineVariant: const Color(0xFFDDE3EA),
      error: const Color(0xFFDC2626),
    );

    return _base(scheme, EvidenceColors.light)
        .copyWith(scaffoldBackgroundColor: const Color(0xFFF6F8FA));
  }

  static ThemeData get dark {
    final scheme = ColorScheme.fromSeed(
      seedColor: _navy,
      brightness: Brightness.dark,
    ).copyWith(
      primary: const Color(0xFFCBD5E1),
      onPrimary: const Color(0xFF0B1220),
      secondary: const Color(0xFF94A3B8),
      tertiary: _accentDark,
      surface: const Color(0xFF141C26),
      surfaceContainerHighest: const Color(0xFF1E2937),
      outlineVariant: const Color(0xFF2D3B4D),
      error: const Color(0xFFF87171),
    );

    return _base(scheme, EvidenceColors.dark)
        .copyWith(scaffoldBackgroundColor: const Color(0xFF0B1220));
  }

  static ThemeData _base(ColorScheme scheme, EvidenceColors evidence) {
    final onSurfaceMuted = scheme.onSurfaceVariant;

    // Explicit type scale rather than Material's defaults. The point is a
    // deliberate step between sizes and a weight hierarchy that carries
    // structure — headings 700, labels 600, body 400.
    final text = TextTheme(
      displaySmall: TextStyle(
        fontSize: 32,
        height: 1.2,
        fontWeight: FontWeight.w800,
        letterSpacing: -0.5,
        color: scheme.onSurface,
      ),
      headlineSmall: TextStyle(
        fontSize: 22,
        height: 1.3,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.2,
        color: scheme.onSurface,
      ),
      titleLarge: TextStyle(
        fontSize: 18,
        height: 1.35,
        fontWeight: FontWeight.w700,
        color: scheme.onSurface,
      ),
      titleMedium: TextStyle(
        fontSize: 15,
        height: 1.4,
        fontWeight: FontWeight.w600,
        color: scheme.onSurface,
      ),
      titleSmall: TextStyle(
        fontSize: 13.5,
        height: 1.4,
        fontWeight: FontWeight.w600,
        color: scheme.onSurface,
      ),
      // 1.55 line-height on body — inside the 1.5–1.75 readable band.
      bodyLarge: TextStyle(
        fontSize: 15,
        height: 1.55,
        fontWeight: FontWeight.w400,
        color: scheme.onSurface,
      ),
      bodyMedium: TextStyle(
        fontSize: 13.5,
        height: 1.55,
        fontWeight: FontWeight.w400,
        color: scheme.onSurface,
      ),
      bodySmall: TextStyle(
        fontSize: 12.5,
        height: 1.5,
        fontWeight: FontWeight.w400,
        color: onSurfaceMuted,
      ),
      labelLarge: TextStyle(
        fontSize: 13.5,
        height: 1.3,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.1,
        color: scheme.onSurface,
      ),
      labelMedium: TextStyle(
        fontSize: 12,
        height: 1.3,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.3,
        color: scheme.onSurface,
      ),
      // Uppercase eyebrow labels get real tracking; without it they read as
      // shouting rather than as a label.
      labelSmall: TextStyle(
        fontSize: 11,
        height: 1.3,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.6,
        color: onSurfaceMuted,
      ),
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      textTheme: text,
      extensions: [evidence],
      visualDensity: VisualDensity.standard,

      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 1,
        centerTitle: false,
        titleTextStyle: text.titleLarge,
        shape: Border(
          bottom: BorderSide(color: scheme.outlineVariant, width: 1),
        ),
      ),

      // Flat, outlined cards — an audit surface should look like a document,
      // not a floating tile. Elevation is reserved for things that genuinely
      // sit above the page (dialogs, menus).
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surface,
        surfaceTintColor: Colors.transparent,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.surface),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),

      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        thickness: 1,
        space: Spacing.xl,
      ),

      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          // 48 tall clears the 44pt minimum touch target with room to spare.
          minimumSize: const Size(0, 48),
          padding: const EdgeInsets.symmetric(horizontal: Spacing.xl),
          backgroundColor: scheme.tertiary,
          foregroundColor: Colors.white,
          textStyle: text.labelLarge,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Radii.control),
          ),
        ),
      ),

      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 48),
          padding: const EdgeInsets.symmetric(horizontal: Spacing.xl),
          foregroundColor: scheme.onSurface,
          textStyle: text.labelLarge,
          side: BorderSide(color: scheme.outlineVariant),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Radii.control),
          ),
        ),
      ),

      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(0, 40),
          foregroundColor: scheme.tertiary,
          textStyle: text.labelLarge,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Radii.control),
          ),
        ),
      ),

      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surface,
        isDense: false,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: Spacing.md,
          vertical: Spacing.md,
        ),
        labelStyle: text.bodyMedium?.copyWith(color: onSurfaceMuted),
        hintStyle: text.bodyMedium?.copyWith(color: onSurfaceMuted),
        helperStyle: text.bodySmall,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Radii.control),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Radii.control),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Radii.control),
          // 2px focus ring, visible for keyboard navigation.
          borderSide: BorderSide(color: scheme.tertiary, width: 2),
        ),
      ),

      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: scheme.inverseSurface,
        contentTextStyle: text.bodyMedium?.copyWith(
          color: scheme.onInverseSurface,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.control),
        ),
      ),

      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.surface),
        ),
        titleTextStyle: text.titleSmall,
        subtitleTextStyle: text.bodySmall,
      ),

      // Navigation is chrome, not content: it sits on the surface colour with a
      // single hairline separating it, and the selected state is carried by a
      // quiet tinted pill rather than a saturated block. A navigation rail that
      // competes with the data next to it is a rail the reader has to look past
      // on every glance.
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: scheme.surface,
        indicatorColor: scheme.tertiary.withValues(alpha: 0.12),
        selectedIconTheme: IconThemeData(size: 21, color: scheme.tertiary),
        unselectedIconTheme: IconThemeData(size: 21, color: onSurfaceMuted),
        selectedLabelTextStyle: text.labelMedium?.copyWith(
          color: scheme.tertiary,
        ),
        unselectedLabelTextStyle: text.labelMedium?.copyWith(
          color: onSurfaceMuted,
          fontWeight: FontWeight.w500,
        ),
        useIndicator: true,
      ),

      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: scheme.tertiary.withValues(alpha: 0.12),
        elevation: 0,
        height: 64,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            size: 21,
            color: states.contains(WidgetState.selected)
                ? scheme.tertiary
                : onSurfaceMuted,
          ),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => text.labelMedium?.copyWith(
            color: states.contains(WidgetState.selected)
                ? scheme.tertiary
                : onSurfaceMuted,
          ),
        ),
      ),

      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.surface),
        ),
        titleTextStyle: text.titleLarge,
        contentTextStyle: text.bodyMedium,
      ),
    );
  }
}
