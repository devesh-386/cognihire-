/// The app's design system: colour tokens, type scale, and component themes.
///
/// ## Golden Taupe — the third palette, and why
///
/// The first build seeded Material 3 from `0xFF4F46E5`, an indigo-violet that
/// read as "AI startup" — precisely the wrong signal for a product whose whole
/// argument is that it is *not* another AI interview tool. That was replaced by
/// a slate navy, which was sober but generic: it read as "enterprise dashboard"
/// and said nothing.
///
/// This palette is **Golden Taupe**, from `design/golden_taupe.md`: warm
/// near-white surfaces, a muted-gold accent, and taupe structure. The brief
/// calls it "understated luxury" and it earns something the navy did not — it
/// looks like a *document* rather than a console, which is what an audit record
/// is. Warm neutrals also separate this product from every blue-grey AI tool it
/// will be compared against.
///
/// ### One deliberate deviation from the source palette
///
/// The brief specifies `#C5A059` as the primary button fill with off-white
/// text. That pairing measures about 2.4:1, which fails the WCAG AA floor the
/// same document mandates two paragraphs earlier. Where the two rules conflict
/// the contrast rule wins: solid actions use the darker `#775A19` (≈6.6:1 on
/// white) and `#C5A059` is kept for accents, rings, underlines, and fills that
/// never carry text. The gold reads the same; it is simply legible.
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

import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
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

  /// Between major sections of a page. The Golden Taupe brief mandates 48px and
  /// 80px vertical rhythm between top-level regions so the interface reads as
  /// "airy and deliberate"; these two names exist so that intent is stated
  /// rather than approximated by stacking [xxxl] twice.
  static const double section = 48;
  static const double hero = 80;
}

/// Corner radii.
///
/// [surface] is 16 rather than 12 because the brief treats cards as "primary
/// content buckets" and gives them `rounded-lg`. Controls stay at 8 so a button
/// inside a card is visibly a different class of object.
abstract final class Radii {
  static const double control = 8;
  static const double surface = 16;
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

  /// Warm-shifted for the Golden Taupe surfaces: the greens and reds carry a
  /// touch of yellow so they sit on `#FCF9F8` as chosen colours rather than as
  /// imports from a cooler palette. "Unmeasured" moved further from the brand
  /// gold than it was from the old blue accent — on a gold-accented page an
  /// amber caution would otherwise read as decoration.
  static const light = EvidenceColors(
    verified: Color(0xFF2F6B41),
    verifiedContainer: Color(0xFFE1EFE4),
    disputed: Color(0xFFBA1A1A),
    disputedContainer: Color(0xFFFFDAD6),
    unmeasured: Color(0xFF8A5A12),
    unmeasuredContainer: Color(0xFFF7EBD6),
    notExamined: Color(0xFF7F7667),
    notExaminedContainer: Color(0xFFF0EDED),
  );

  static const dark = EvidenceColors(
    verified: Color(0xFF86D29B),
    verifiedContainer: Color(0xFF23402C),
    disputed: Color(0xFFFFB4AB),
    disputedContainer: Color(0xFF5A1B18),
    unmeasured: Color(0xFFE9C176),
    unmeasuredContainer: Color(0xFF43331A),
    notExamined: Color(0xFFB5AB9B),
    notExaminedContainer: Color(0xFF2C2823),
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

/// The gold accents, kept off the [ColorScheme] on purpose.
///
/// [accent] is `#C5A059` — the brief's headline gold. It fails AA against both
/// white and near-black, so it must never be a text or fill-behind-text colour.
/// Putting it here rather than in the scheme means Material can never
/// accidentally pick it for a label: everything that uses it uses it knowingly,
/// for rings, underlines, hairlines, and chart marks.
class BrandAccents extends ThemeExtension<BrandAccents> {
  const BrandAccents({
    required this.accent,
    required this.accentSoft,
    required this.cream,
    required this.railSurface,
  });

  /// Decorative gold. Rings, bar fills, active underlines, focus glows.
  final Color accent;

  /// The same gold at low intensity, for tinted backgrounds behind dark text.
  final Color accentSoft;

  /// Soft cream layering colour — hover states and subtle background shifts.
  final Color cream;

  /// The navigation column's own surface. The brief anchors structure by giving
  /// the sidebar a different value from the content area rather than a border.
  final Color railSurface;

  static const light = BrandAccents(
    accent: Color(0xFFC5A059),
    accentSoft: Color(0xFFF6ECD9),
    cream: Color(0xFFF6F3F2),
    railSurface: Color(0xFFF8F5F3),
  );

  static const dark = BrandAccents(
    accent: Color(0xFFE9C176),
    accentSoft: Color(0xFF3A2F1B),
    cream: Color(0xFF262220),
    railSurface: Color(0xFF17140F),
  );

  @override
  BrandAccents copyWith({
    Color? accent,
    Color? accentSoft,
    Color? cream,
    Color? railSurface,
  }) =>
      BrandAccents(
        accent: accent ?? this.accent,
        accentSoft: accentSoft ?? this.accentSoft,
        cream: cream ?? this.cream,
        railSurface: railSurface ?? this.railSurface,
      );

  @override
  BrandAccents lerp(ThemeExtension<BrandAccents>? other, double t) {
    if (other is! BrandAccents) return this;
    return BrandAccents(
      accent: Color.lerp(accent, other.accent, t)!,
      accentSoft: Color.lerp(accentSoft, other.accentSoft, t)!,
      cream: Color.lerp(cream, other.cream, t)!,
      railSurface: Color.lerp(railSurface, other.railSurface, t)!,
    );
  }
}

extension BrandAccentsX on BuildContext {
  BrandAccents get brand =>
      Theme.of(this).extension<BrandAccents>() ?? BrandAccents.light;
}

abstract final class AppTheme {
  // Golden Taupe. `_gold` is the *action* gold: dark enough to carry white text
  // at AA. The decorative `#C5A059` lives on [BrandAccents.accent].
  static const _gold = Color(0xFF775A19);
  static const _goldDark = Color(0xFFE9C176);
  static const _taupe = Color(0xFF6C5B4E);

  static ThemeData get light {
    final scheme = ColorScheme.fromSeed(
      seedColor: _gold,
      brightness: Brightness.light,
    ).copyWith(
      primary: _gold,
      onPrimary: Colors.white,
      primaryContainer: const Color(0xFFFFDEA5),
      onPrimaryContainer: const Color(0xFF4E3700),
      secondary: _taupe,
      onSecondary: Colors.white,
      secondaryContainer: const Color(0xFFF2DCCB),
      onSecondaryContainer: const Color(0xFF3F3428),
      // Actions resolve through `tertiary` throughout this app, so pointing it
      // at the same action gold is what makes every existing button, focus
      // ring, and rail indicator adopt the palette without being touched.
      tertiary: _gold,
      onTertiary: Colors.white,
      surface: const Color(0xFFFCF9F8),
      onSurface: const Color(0xFF1C1B1B),
      // Warm, not neutral: on a `#FCF9F8` page a grey container reads as dirty.
      surfaceContainerHighest: const Color(0xFFEAE7E7),
      onSurfaceVariant: const Color(0xFF4E4639),
      outline: const Color(0xFF7F7667),
      outlineVariant: const Color(0xFFD1C5B4),
      error: const Color(0xFFBA1A1A),
      errorContainer: const Color(0xFFFFDAD6),
      onErrorContainer: const Color(0xFF93000A),
    );

    return _base(scheme, EvidenceColors.light, BrandAccents.light)
        .copyWith(scaffoldBackgroundColor: const Color(0xFFF6F3F2));
  }

  /// The brief's "Deep Taupe" dark variant: warm near-black surfaces and soft
  /// cream ink, rather than the palette's light values naively inverted.
  static ThemeData get dark {
    final scheme = ColorScheme.fromSeed(
      seedColor: _gold,
      brightness: Brightness.dark,
    ).copyWith(
      primary: _goldDark,
      onPrimary: const Color(0xFF261900),
      primaryContainer: const Color(0xFF5D4201),
      onPrimaryContainer: const Color(0xFFFFDEA5),
      secondary: const Color(0xFFD8C3B3),
      onSecondary: const Color(0xFF25190F),
      secondaryContainer: const Color(0xFF534438),
      onSecondaryContainer: const Color(0xFFF5DECE),
      tertiary: _goldDark,
      onTertiary: const Color(0xFF261900),
      surface: const Color(0xFF1F1B18),
      onSurface: const Color(0xFFF3F0EF),
      surfaceContainerHighest: const Color(0xFF322D28),
      onSurfaceVariant: const Color(0xFFD4C9BA),
      outline: const Color(0xFF9C9083),
      outlineVariant: const Color(0xFF3E3830),
      error: const Color(0xFFFFB4AB),
      errorContainer: const Color(0xFF5A1B18),
      onErrorContainer: const Color(0xFFFFDAD6),
    );

    return _base(scheme, EvidenceColors.dark, BrandAccents.dark)
        .copyWith(scaffoldBackgroundColor: const Color(0xFF14110E));
  }

  static ThemeData _base(
    ColorScheme scheme,
    EvidenceColors evidence,
    BrandAccents brand,
  ) {
    final onSurfaceMuted = scheme.onSurfaceVariant;

    // Explicit type scale rather than Material's defaults. The point is a
    // deliberate step between sizes and a weight hierarchy that carries
    // structure — headings 700, labels 600, body 400.
    //
    // Apple type rule: tracking and leading are size-specific and inverse to
    // each other — the larger the type, the tighter both get. So the display
    // face carries the most-negative tracking (-0.037em) and the tightest
    // leading (1.06), easing toward neutral tracking and 1.55 leading on body.
    // Optical: at 32px a fixed -0.5 was under-tight and 1.2 leading left
    // headings looking loose next to the tightened portal.
    final text = TextTheme(
      displaySmall: TextStyle(
        fontSize: 32,
        height: 1.06,
        fontWeight: FontWeight.w800,
        letterSpacing: -1.2,
        color: scheme.onSurface,
      ),
      headlineSmall: TextStyle(
        fontSize: 22,
        height: 1.15,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.55,
        color: scheme.onSurface,
      ),
      titleLarge: TextStyle(
        fontSize: 18,
        height: 1.25,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.3,
        color: scheme.onSurface,
      ),
      titleMedium: TextStyle(
        fontSize: 15,
        height: 1.4,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.15,
        color: scheme.onSurface,
      ),
      titleSmall: TextStyle(
        fontSize: 13.5,
        height: 1.4,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.1,
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
      extensions: [evidence, brand],
      visualDensity: VisualDensity.standard,

      // Apple motion rule: route changes read as one continuous, spring-like
      // move rather than a fade. The shared-axis transition slides along the
      // horizontal axis with Material 3's emphasised easing (a critically
      // damped curve, no overshoot) — directional and interruptible, and it
      // telegraphs where the new screen comes from. `FadeForwardsPageTransitionsBuilder`
      // is M3's own take on this and falls back to a plain fade under
      // `MediaQuery.disableAnimations` (which reduce-motion sets), so it needs
      // no separate reduced-motion branch.
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
        },
      ),

      // Feedback on press, not release, and quicker to depress than to release
      // (Apple: the touch-down state should feel instant). A shorter splash
      // fade-in makes the ripple track the finger rather than lag it.
      splashFactory: InkSparkle.splashFactory,

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
          // Not hardcoded white: the dark theme's action gold is light, and
          // white-on-light-gold was unreadable while it was a literal.
          foregroundColor: scheme.onTertiary,
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
        // A different value from the content area, which is how the brief
        // anchors structure — no border needed to say "this column is chrome".
        backgroundColor: brand.railSurface,
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

      // Chips are pills by the brief, and are never actions — a chip that looked
      // like a button would invite a click that does nothing.
      chipTheme: ChipThemeData(
        backgroundColor: brand.cream,
        side: BorderSide(color: scheme.outlineVariant),
        labelStyle: text.labelMedium?.copyWith(color: onSurfaceMuted),
        padding: const EdgeInsets.symmetric(
          horizontal: Spacing.sm,
          vertical: Spacing.xs,
        ),
        shape: const StadiumBorder(),
      ),

      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: scheme.inverseSurface,
          borderRadius: BorderRadius.circular(Radii.control),
        ),
        textStyle: text.bodySmall?.copyWith(color: scheme.onInverseSurface),
        waitDuration: const Duration(milliseconds: 400),
      ),

      popupMenuTheme: PopupMenuThemeData(
        color: scheme.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 3,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.control),
          side: BorderSide(color: scheme.outlineVariant),
        ),
        textStyle: text.bodyMedium,
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
