import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Sakshya's colour roles. One colour means one thing:
/// [accent] is the brand (wine), [danger] is SOS and recording only,
/// [success] is sealed or verified, [warning] is "needs your attention".
///
/// Contrast figures are against [surface] in the same appearance.
@immutable
class SakColors extends ThemeExtension<SakColors> {
  const SakColors({
    required this.background,
    required this.surface,
    required this.surfaceRaised,
    required this.separator,
    required this.ink,
    required this.inkSecondary,
    required this.inkTertiary,
    required this.accent,
    required this.onAccent,
    required this.accentSoft,
    required this.danger,
    required this.onDanger,
    required this.dangerSoft,
    required this.success,
    required this.successSoft,
    required this.warning,
    required this.warningSoft,
  });

  final Color background;
  final Color surface;
  final Color surfaceRaised;
  final Color separator;
  final Color ink;
  final Color inkSecondary;
  final Color inkTertiary;
  final Color accent;
  final Color onAccent;
  final Color accentSoft;
  final Color danger;
  final Color onDanger;
  final Color dangerSoft;
  final Color success;
  final Color successSoft;
  final Color warning;
  final Color warningSoft;

  static const light = SakColors(
    background: Color(0xFFF6F1F2),
    surface: Color(0xFFFFFFFF),
    surfaceRaised: Color(0xFFFFFFFF),
    separator: Color(0xFFE6DCDE),
    ink: Color(0xFF1C1013), // 18.6:1
    inkSecondary: Color(0xFF6E5A5F), // 6.4:1
    inkTertiary: Color(0xFF8C7A7E), // 4.1:1, icons and large text only
    accent: Color(0xFF7A1F33), // 10.1:1
    onAccent: Color(0xFFFFFFFF),
    accentSoft: Color(0xFFF7D6DC),
    danger: Color(0xFFD92D3A), // white on it 4.8:1
    onDanger: Color(0xFFFFFFFF),
    dangerSoft: Color(0xFFFBE3E4),
    success: Color(0xFF1E7A4C), // 5.6:1
    successSoft: Color(0xFFDDF1E6),
    warning: Color(0xFF9A5600), // 5.3:1
    warningSoft: Color(0xFFFCEBD3),
  );

  static const dark = SakColors(
    background: Color(0xFF110A0C),
    surface: Color(0xFF1E1416),
    surfaceRaised: Color(0xFF2A1D20),
    separator: Color(0xFF3A2B2F),
    ink: Color(0xFFF6EDEF), // 16.0:1
    inkSecondary: Color(0xFFB9A6AA), // 7.8:1
    inkTertiary: Color(0xFF8E7B80), // 4.4:1
    accent: Color(0xFFF2A7B5), // 9.6:1
    onAccent: Color(0xFF3A0B16),
    accentSoft: Color(0xFF3D1C24),
    danger: Color(0xFFE5484D), // white on it 3.9:1, bold 17 pt labels only
    onDanger: Color(0xFFFFFFFF),
    dangerSoft: Color(0xFF3F1A1D),
    success: Color(0xFF4CC38A), // 8.4:1
    successSoft: Color(0xFF15301F),
    warning: Color(0xFFF0B44C), // 9.9:1
    warningSoft: Color(0xFF35260E),
  );

  @override
  SakColors copyWith() => this;

  @override
  SakColors lerp(ThemeExtension<SakColors>? other, double t) {
    if (other is! SakColors) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return SakColors(
      background: l(background, other.background),
      surface: l(surface, other.surface),
      surfaceRaised: l(surfaceRaised, other.surfaceRaised),
      separator: l(separator, other.separator),
      ink: l(ink, other.ink),
      inkSecondary: l(inkSecondary, other.inkSecondary),
      inkTertiary: l(inkTertiary, other.inkTertiary),
      accent: l(accent, other.accent),
      onAccent: l(onAccent, other.onAccent),
      accentSoft: l(accentSoft, other.accentSoft),
      danger: l(danger, other.danger),
      onDanger: l(onDanger, other.onDanger),
      dangerSoft: l(dangerSoft, other.dangerSoft),
      success: l(success, other.success),
      successSoft: l(successSoft, other.successSoft),
      warning: l(warning, other.warning),
      warningSoft: l(warningSoft, other.warningSoft),
    );
  }
}

/// Spacing on a 4 pt grid.
abstract final class SakSpace {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;

  /// Side gutter for every screen.
  static const double gutter = 20;
}

abstract final class SakRadius {
  static const double control = 14;
  static const double card = 20;
  static const double sheet = 28;
}

/// Monospace for hashes, IDs and recovery codes: they are read character
/// by character, so every glyph gets the same width.
abstract final class SakMono {
  static const String family = 'monospace';
  static const List<String> fallback = ['RobotoMono', 'Menlo', 'Courier'];
}

/// Motion. Everything settles on a critically damped spring (no overshoot):
/// nothing here is thrown by a gesture, so nothing bounces.
abstract final class SakMotion {
  static const Duration quick = Duration(milliseconds: 180);
  static const Duration standard = Duration(milliseconds: 340);
  static const Duration slow = Duration(milliseconds: 560);

  static const Curve spring = _CriticalSpring();

  /// Respect the system "remove animations" setting: callers get zero
  /// duration and fall back to a plain cross-fade or no motion.
  static bool reduced(BuildContext context) =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  static Duration of(BuildContext context, Duration d) =>
      reduced(context) ? Duration.zero : d;
}

/// x(t) = 1 − (1 + ωt)·e^(−ωt), normalised so it lands exactly on 1.
class _CriticalSpring extends Curve {
  const _CriticalSpring();

  static const double _omega = 8;
  static final double _end = 1 - (1 + _omega) * math.exp(-_omega);

  @override
  double transformInternal(double t) {
    final wt = _omega * t;
    return (1 - (1 + wt) * math.exp(-wt)) / _end;
  }
}

extension SakTheme on BuildContext {
  /// The colour roles, falling back to the plain palette when a screen is
  /// shown outside the app theme (widget tests pump a bare MaterialApp).
  SakColors get sak {
    final theme = Theme.of(this);
    return theme.extension<SakColors>() ??
        (theme.brightness == Brightness.dark ? SakColors.dark : SakColors.light);
  }

  TextTheme get type => Theme.of(this).textTheme;
}
