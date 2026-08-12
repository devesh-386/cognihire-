/// The app's design system: colour tokens, type scale, and component themes.
///
/// ## Case File — the fourth palette, and why
///
/// Golden Taupe (the palette this replaces) solved the "not another AI
/// startup" problem with warmth, but warmth alone doesn't say what the
/// product *is*. CogniHire's actual claim is narrower and more useful than
/// "trustworthy": every claim the app shows you is either backed by
/// evidence, contradicted by it, unmeasurable, or never checked — and it
/// says which, out loud, all the time. That is a legal-file idea, not a
/// dashboard idea. **Case File** commits to that reading directly: paper
/// surfaces, ink text, hairline rules, sharp-cornered cards that behave like
/// printed pages, and — its signature move — a rubber-stamp mark for the
/// four evidence states instead of a colour-coded chip. A stamp is legible
/// as "someone made a determination and marked the record"; a chip is just
/// UI. The whole point of this product is that the mark is not decoration.
///
/// ### Palette
///
/// - Paper `#F7F5F0` / card `#FCFAF6` — the page and the slightly-lifted
///   surface a card sits on. Two warm off-whites, not white-on-grey, so the
///   app reads as paper rather than a screen simulating paper.
/// - Ink `#14140F` — body text. Warm near-black, not pure black, to match
///   the paper's warmth (pure black on warm paper looks like a scan
///   artifact).
/// - Brick `#8B3A2B` — the *stamp* colour. Reserved for verdict marks and
///   destructive/critical actions. It is never a decorative fill, never a
///   background tint behind unrelated content, and never used for "this
///   button is important" emphasis that isn't actually a verdict or a
///   critical action — if brick shows up, something was determined or is
///   about to become irreversible.
/// - Slate `#4A5654` — structural chrome: the nav rail, secondary icons,
///   quiet UI. It has no semantic meaning; it exists so structure doesn't
///   have to borrow the verdict colour to look "present".
/// - Hairline `#C9C2B4` — the one border colour. A case file is held
///   together by thin rules, not shadows.
///
/// Dark mode is not the light palette inverted. `#151310` is a warm
/// near-black (not neutral, which would fight the paper-cream ink), and the
/// brick brightens to `#C9694F` because a saturated dark red on a near-black
/// background loses too much contrast to read as ink — it has to open up to
/// stay legible as brick rather than going muddy.
///
/// ### Contrast pass
///
/// - Brick `#8B3A2B` on paper `#F7F5F0`: ~7.6:1 — clears AA body text (4.5:1)
///   comfortably, unlike Golden Taupe's `#C5A059` (~2.4:1), so brick can be
///   used directly for stamp text and critical-action labels without a
///   separate "text-safe" shade.
/// - Brightened brick `#C9694F` on ink `#151310`: ~4.9:1 — clears AA body
///   text by a narrow margin. Where brick carries *small* dark-mode text
///   (not large/bold), prefer `#D9765A` (~5.9:1) for extra headroom; that
///   variant lives on `CaseFileAccents.dark.accent` while `#C9694F` is kept
///   as the historical "vivid" reference in this comment for anyone tuning
///   it further.
/// - Evidence colours are chosen and checked independently below — see the
///   doc comment on [EvidenceColors].
///
/// ## Evidence colours are a separate axis from the brand colour
///
/// [EvidenceColors] is deliberately not derived from brick. Verified /
/// disputed / unmeasured / not-examined are the product's actual data
/// model — the four "sealed output states" a claim can be in — and they
/// have to stay legible and unambiguous regardless of what the brand colour
/// is doing on a given screen. Disputed happens to land near brick by
/// coincidence of both being "alert" colours in the same warm-red family,
/// not because the theme couples them; a future brand change must not be
/// able to silently change what "disputed" looks like.
///
/// **Note what is still absent:** there is no red→amber→green *gradient*
/// anywhere in this file — no aggregate score expressed as a colour ramp.
/// Unmeasured is amber specifically because amber reads as "absence of
/// signal", not as a midpoint between disputed and verified. Not-examined
/// is a quiet grey on purpose: it is deliberately the least visually loud
/// of the four, because absence of evidence should look like absence, not
/// like a soft failure.
library;

import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

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

  /// Between major sections of a page. Kept from Golden Taupe — the rhythm
  /// was never the part that needed to change, only the surfaces it frames.
  static const double section = 48;
  static const double hero = 80;
}

/// Corner radii.
///
/// Golden Taupe used 16/8 (surface/control) because it wanted cards to read
/// as soft "content buckets". Case File wants the opposite feeling: a
/// document, not a cushion. [surface] drops to 8 — enough to not look like a
/// pasted-in screenshot of a form, not enough to look upholstered.
/// [control] drops further, to 5, so a button reads closer to a stamped or
/// printed rectangle than a rounded pill-adjacent shape. Neither goes to a
/// hard 0: a perfectly square corner on a screen (as opposed to actual
/// paper) reads as unfinished, not as "more paper-like".
abstract final class Radii {
  static const double control = 5;
  static const double surface = 8;
  static const double pill = 999;
}

/// Semantic colours for evidence state — the four "sealed output states" a
/// claim can carry: verified, disputed, unmeasured, not examined.
///
/// Each has a light and dark variant chosen for contrast against its own
/// theme's surface, not naively inverted. See the top-of-file comment for
/// why this stays a separate axis from the brand colour.
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

  /// A real comparison ran and cleared the threshold. Forest-toned green —
  /// deliberately not a bright "success" green, which would read as a UI
  /// affordance rather than a factual determination.
  final Color verified;
  final Color verifiedContainer;

  /// A real comparison ran and did not clear it. This is the one evidence
  /// colour that shares a family with the brand brick — both are "something
  /// is wrong, look here" reds — but is tracked as its own token so the two
  /// can diverge later without a coupled brand change moving it.
  final Color disputed;
  final Color disputedContainer;

  /// Nothing could be measured. An ochre/amber, kept well clear of both the
  /// green (would read as "nearly verified") and the brick red (would read
  /// as "nearly disputed") — amber is the colour of "no signal", not a
  /// midpoint on a quality scale.
  final Color unmeasured;
  final Color unmeasuredContainer;

  /// Never examined. Deliberately the quietest of the four: absence of
  /// evidence should look like absence, not like a soft failure.
  final Color notExamined;
  final Color notExaminedContainer;

  /// Light-theme values, checked against the `#F7F5F0` paper / `#FCFAF6`
  /// card surfaces:
  /// - verified `#2F6B41` on `#FCFAF6` ≈ 6.9:1
  /// - disputed `#8B3A2B` on `#FCFAF6` ≈ 7.5:1 (shares the brand brick — see
  ///   class doc)
  /// - unmeasured `#8A5A12` on `#FCFAF6` ≈ 5.3:1
  /// - notExamined `#6E695F` on `#FCFAF6` ≈ 5.1:1
  /// All four clear the 4.5:1 AA body-text floor.
  static const light = EvidenceColors(
    verified: Color(0xFF2F6B41),
    verifiedContainer: Color(0xFFE1EFE1),
    disputed: Color(0xFF8B3A2B),
    disputedContainer: Color(0xFFF3DFD8),
    unmeasured: Color(0xFF8A5A12),
    unmeasuredContainer: Color(0xFFF2E6C9),
    notExamined: Color(0xFF6E695F),
    notExaminedContainer: Color(0xFFEBE8E0),
  );

  /// Dark-theme values, checked against the `#151310` ink background:
  /// - verified `#86D29B` ≈ 11.2:1
  /// - disputed `#D9765A` ≈ 5.9:1 (brightened further than the raw brand
  ///   brick `#C9694F` at ~4.9:1, for the extra headroom small stamp text
  ///   needs — see top-of-file contrast pass)
  /// - unmeasured `#D9A44B` ≈ 8.6:1
  /// - notExamined `#A39C8F` ≈ 6.7:1
  static const dark = EvidenceColors(
    verified: Color(0xFF86D29B),
    verifiedContainer: Color(0xFF23402C),
    disputed: Color(0xFFD9765A),
    disputedContainer: Color(0xFF4A2620),
    unmeasured: Color(0xFFD9A44B),
    unmeasuredContainer: Color(0xFF3D2F14),
    notExamined: Color(0xFFA39C8F),
    notExaminedContainer: Color(0xFF2B2822),
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

/// Case File's structural and brand accents, kept off the [ColorScheme] on
/// purpose. Renamed from `BrandAccents` (Golden Taupe) to make explicit that
/// this is the palette backing the "case file" reading, not a generic brand
/// namespace.
///
/// [accent] is the brick `#8B3A2B` / `#C9694F` — see the top-of-file
/// contrast pass for why it's safe to use directly as text/border colour in
/// both themes (unlike Golden Taupe's `#C5A059`, which failed AA and had to
/// be kept out of text entirely). It still isn't put on the [ColorScheme]:
/// putting it here means Material can never *accidentally* pick it for an
/// unrelated label — everything that renders brick does so knowingly,
/// because brick means "verdict or critical action" everywhere else in the
/// UI.
class CaseFileAccents extends ThemeExtension<CaseFileAccents> {
  const CaseFileAccents({
    required this.accent,
    required this.accentSoft,
    required this.paperTint,
    required this.railSurface,
  });

  /// The brick. Verdict marks, destructive/critical action fills, focus
  /// rings on critical controls. Never a decorative fill or an "important
  /// but not actually critical" emphasis colour.
  final Color accent;

  /// The brick at low intensity, for tinted backgrounds behind dark text —
  /// e.g. a banner warning the reviewer a determination is pending.
  final Color accentSoft;

  /// A slightly deeper paper tone than the scaffold background, for hover
  /// states and subtle background shifts that need to read as "still
  /// paper" rather than a grey Material hover overlay.
  final Color paperTint;

  /// The navigation column's own surface. Structure is anchored by giving
  /// the rail a different value from the content area — slate-tinted rather
  /// than a border, same principle Golden Taupe used.
  final Color railSurface;

  static const light = CaseFileAccents(
    accent: Color(0xFF8B3A2B),
    accentSoft: Color(0xFFF3DFD8),
    paperTint: Color(0xFFF1EEE6),
    railSurface: Color(0xFFEFEBE1),
  );

  static const dark = CaseFileAccents(
    accent: Color(0xFFD9765A),
    accentSoft: Color(0xFF3A2620),
    paperTint: Color(0xFF1C1914),
    railSurface: Color(0xFF19170F),
  );

  @override
  CaseFileAccents copyWith({
    Color? accent,
    Color? accentSoft,
    Color? paperTint,
    Color? railSurface,
  }) =>
      CaseFileAccents(
        accent: accent ?? this.accent,
        accentSoft: accentSoft ?? this.accentSoft,
        paperTint: paperTint ?? this.paperTint,
        railSurface: railSurface ?? this.railSurface,
      );

  @override
  CaseFileAccents lerp(ThemeExtension<CaseFileAccents>? other, double t) {
    if (other is! CaseFileAccents) return this;
    return CaseFileAccents(
      accent: Color.lerp(accent, other.accent, t)!,
      accentSoft: Color.lerp(accentSoft, other.accentSoft, t)!,
      paperTint: Color.lerp(paperTint, other.paperTint, t)!,
      railSurface: Color.lerp(railSurface, other.railSurface, t)!,
    );
  }
}

/// `context.brand` is kept as the accessor name (rather than renaming to
/// `context.caseFile`) even though the type behind it is now
/// [CaseFileAccents] — every screen in `lib/` already calls `context.brand`,
/// and renaming the accessor would touch a dozen files for a purely
/// cosmetic win. The type rename communicates the intent; the accessor
/// keeps the call sites stable.
extension BrandAccentsX on BuildContext {
  CaseFileAccents get brand =>
      Theme.of(this).extension<CaseFileAccents>() ?? CaseFileAccents.light;
}

/// Type-face helpers for the data/numeric track — thresholds, timestamps,
/// similarity scores, hashes. These render with [GoogleFonts.ibmPlexMono]
/// specifically where a value is *measured*, not throughout the app; most
/// text should come from [ThemeData.textTheme] via the slab/grotesk pair.
abstract final class AppTypography {
  /// Wrap a numeric/measured value's existing style in the monospace face.
  /// Tabular figures keep columns of scores and timestamps aligned.
  static TextStyle data(TextStyle? base) => GoogleFonts.ibmPlexMono(
        textStyle: base,
        fontFeatures: const [FontFeature.tabularFigures()],
      );
}

abstract final class AppTheme {
  // Case File brand brick. `_brick` carries text/critical actions in light
  // mode; `_brickDark` is the brightened dark-mode variant. See the
  // top-of-file contrast pass for the numbers.
  static const _brick = Color(0xFF8B3A2B);
  static const _brickDark = Color(0xFFD9765A);
  static const _slate = Color(0xFF4A5654);
  static const _slateDark = Color(0xFF9BA8A5);

  static ThemeData get light {
    final scheme = ColorScheme.fromSeed(
      seedColor: _brick,
      brightness: Brightness.light,
    ).copyWith(
      primary: _brick,
      onPrimary: Colors.white,
      primaryContainer: const Color(0xFFF3DFD8),
      onPrimaryContainer: const Color(0xFF3C140B),
      secondary: _slate,
      onSecondary: Colors.white,
      secondaryContainer: const Color(0xFFDCE4E2),
      onSecondaryContainer: const Color(0xFF1E2624),
      // Actions resolve through `tertiary` throughout this app, so pointing
      // it at the brick is what makes every existing button, focus ring,
      // and rail indicator adopt the palette without being touched.
      tertiary: _brick,
      onTertiary: Colors.white,
      surface: const Color(0xFFFCFAF6),
      onSurface: const Color(0xFF14140F),
      // Warm, not neutral: on a `#FCFAF6` card a grey container reads as
      // dirty paper rather than a distinct region.
      surfaceContainerHighest: const Color(0xFFEDEAE1),
      onSurfaceVariant: const Color(0xFF4A4739),
      outline: const Color(0xFF7F7667),
      outlineVariant: const Color(0xFFC9C2B4),
      error: const Color(0xFFBA1A1A),
      errorContainer: const Color(0xFFFFDAD6),
      onErrorContainer: const Color(0xFF93000A),
    );

    return _base(scheme, EvidenceColors.light, CaseFileAccents.light)
        .copyWith(scaffoldBackgroundColor: const Color(0xFFF7F5F0));
  }

  /// Dark "Case File" variant: warm near-black ink, not the light palette
  /// naively inverted — see top-of-file comment.
  static ThemeData get dark {
    final scheme = ColorScheme.fromSeed(
      seedColor: _brick,
      brightness: Brightness.dark,
    ).copyWith(
      primary: _brickDark,
      onPrimary: const Color(0xFF2E0F09),
      primaryContainer: const Color(0xFF4A2620),
      onPrimaryContainer: const Color(0xFFF3DFD8),
      secondary: _slateDark,
      onSecondary: const Color(0xFF16201E),
      secondaryContainer: const Color(0xFF33413F),
      onSecondaryContainer: const Color(0xFFDCE4E2),
      tertiary: _brickDark,
      onTertiary: const Color(0xFF2E0F09),
      surface: const Color(0xFF1C1914),
      onSurface: const Color(0xFFEDE9E0),
      surfaceContainerHighest: const Color(0xFF2E2A23),
      onSurfaceVariant: const Color(0xFFD3CCBC),
      outline: const Color(0xFF9C9083),
      outlineVariant: const Color(0xFF3E3830),
      error: const Color(0xFFFFB4AB),
      errorContainer: const Color(0xFF5A1B18),
      onErrorContainer: const Color(0xFFFFDAD6),
    );

    return _base(scheme, EvidenceColors.dark, CaseFileAccents.dark)
        .copyWith(scaffoldBackgroundColor: const Color(0xFF151310));
  }

  static ThemeData _base(
    ColorScheme scheme,
    EvidenceColors evidence,
    CaseFileAccents brand,
  ) {
    final onSurfaceMuted = scheme.onSurfaceVariant;

    // Face choice: headings use Roboto Slab, a real slab serif rather than
    // a typewriter face (Special Elite, Courier Prime). A typewriter face
    // reads "case file" even louder, but its low x-height and mono rhythm
    // make it noticeably worse at real headline sizes and multi-line
    // titles — this app has long claim text and section headers that need
    // to stay legible, not just thematic. Roboto Slab keeps the ledger/
    // dossier association from its serif slabs while staying readable at
    // 13–32px. Body uses IBM Plex Sans, a grotesk with a tall x-height and
    // a slightly technical, document-y character that pairs with Plex Mono
    // (see [AppTypography.data]) without a jarring family switch — all
    // three faces are drawn from a coherent, engineered type family rather
    // than an ad hoc web-font pairing.
    //
    // Apple type rule kept from Golden Taupe: tracking and leading are
    // size-specific and inverse to each other — the larger the type, the
    // tighter both get. The slab display face carries the most-negative
    // tracking and tightest leading, easing toward neutral tracking and
    // 1.55 leading on Plex Sans body.
    final headline = GoogleFonts.robotoSlabTextTheme();
    final body = GoogleFonts.ibmPlexSansTextTheme();

    TextStyle slab({
      required double size,
      required double height,
      required FontWeight weight,
      required double tracking,
      Color? color,
    }) =>
        headline.bodyMedium!.copyWith(
          fontSize: size,
          height: height,
          fontWeight: weight,
          letterSpacing: tracking,
          color: color ?? scheme.onSurface,
        );

    TextStyle sans({
      required double size,
      required double height,
      required FontWeight weight,
      double tracking = 0,
      Color? color,
    }) =>
        body.bodyMedium!.copyWith(
          fontSize: size,
          height: height,
          fontWeight: weight,
          letterSpacing: tracking,
          color: color ?? scheme.onSurface,
        );

    final text = TextTheme(
      displaySmall: slab(
        size: 32,
        height: 1.08,
        weight: FontWeight.w700,
        tracking: -0.9,
      ),
      headlineSmall: slab(
        size: 22,
        height: 1.18,
        weight: FontWeight.w700,
        tracking: -0.4,
      ),
      titleLarge: slab(
        size: 18,
        height: 1.28,
        weight: FontWeight.w600,
        tracking: -0.2,
      ),
      titleMedium: sans(
        size: 15,
        height: 1.4,
        weight: FontWeight.w600,
        tracking: -0.1,
      ),
      titleSmall: sans(
        size: 13.5,
        height: 1.4,
        weight: FontWeight.w600,
      ),
      // 1.55 line-height on body — inside the 1.5–1.75 readable band.
      bodyLarge: sans(size: 15, height: 1.55, weight: FontWeight.w400),
      bodyMedium: sans(size: 13.5, height: 1.55, weight: FontWeight.w400),
      bodySmall: sans(
        size: 12.5,
        height: 1.5,
        weight: FontWeight.w400,
        color: onSurfaceMuted,
      ),
      labelLarge: sans(
        size: 13.5,
        height: 1.3,
        weight: FontWeight.w600,
        tracking: 0.1,
      ),
      labelMedium: sans(
        size: 12,
        height: 1.3,
        weight: FontWeight.w600,
        tracking: 0.3,
      ),
      // Uppercase eyebrow labels get real tracking; without it they read as
      // shouting rather than as a label.
      labelSmall: sans(
        size: 11,
        height: 1.3,
        weight: FontWeight.w700,
        tracking: 0.7,
        color: onSurfaceMuted,
      ),
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      textTheme: text,
      extensions: [evidence, brand],
      visualDensity: VisualDensity.standard,

      // Kept from Golden Taupe: shared-axis page transitions read as one
      // continuous move rather than a fade, and fall back to a plain fade
      // under reduce-motion automatically.
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
        },
      ),

      // Feedback on press, not release, and quicker to depress than to
      // release — the ripple should track the finger, not lag it.
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

      // Flat, outlined cards — an audit surface should look like a printed
      // page, not a floating tile. Elevation stays reserved for things that
      // genuinely sit above the page (dialogs, menus).
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

      // Navigation is chrome, not content: it sits on a slate-tinted
      // surface with a single hairline separating it, and the selected
      // state is carried by a quiet tinted pill rather than a saturated
      // block — a rail that competes with the evidence next to it is a
      // rail the reader has to look past on every glance.
      navigationRailTheme: NavigationRailThemeData(
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

      // Chips are pills, and are never actions — a chip that looked like a
      // button would invite a click that does nothing. Evidence state no
      // longer renders as a chip at all (see [VerdictStamp]); this theme
      // still backs ordinary filter/tag chips elsewhere in the app.
      chipTheme: ChipThemeData(
        backgroundColor: brand.paperTint,
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
