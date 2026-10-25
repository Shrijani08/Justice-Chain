import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Dark Ember: near-black ground lit by wine and plum glows, frosted
/// glass panels, one ember gradient for SOS. Values are the approved
/// canvas's, one for one. The app is dark only.
abstract final class Ember {
  /// Screen grounds. [home] is the deeper one behind Home and onboarding.
  static const ground = Color(0xFF0A0708);
  static const home = Color(0xFF070506);
  static const black = Color(0xFF000000);

  static const ink = Color(0xFFF4ECEE); // 17.9:1 on ground
  static const ink2 = Color(0xA8F4ECEE); // 66%, 7.6:1
  static const ink3 = Color(0x8CF4ECEE); // 55%, captions only
  static const onPearl = Color(0xFF1A0B10);

  /// Glass: white 6% with a 12% hairline.
  static const glass = Color(0x0FFFFFFF);
  static const glassBorder = Color(0x1FFFFFFF);
  static const hairline = Color(0x12FFFFFF);

  static const emberStart = Color(0xFF8E1B32);
  static const emberEnd = Color(0xFF5A0F22);
  static const emberEdge = Color(0x2EFF8CA0);
  static const destructive = Color(0xFF8E1B32);

  static const rose = Color(0xFFF2A7B5); // links, focus
  static const roseSoft = Color(0xFFFFC6D0);
  static const blush = Color(0xFFD99AAB);
  static const sealed = Color(0xFF5BD6A0);
  static const attention = Color(0xFFF0B44C);
  static const alarm = Color(0xFFE5484D);
  static const alertText = Color(0xFFFF7A88);

  /// Glow tints laid behind content.
  static const wineGlow = Color(0xFF5A1424);
  static const deepWine = Color(0xFF3E0E1C);
  static const plumGlow = Color(0xFF3B1C3F);
  static const nightPlum = Color(0xFF24112A);

  static const emberGradient = LinearGradient(
    begin: Alignment(-1, -0.18),
    end: Alignment(1, 0.18),
    colors: [emberStart, emberEnd],
  );

  static const pearlGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0xFFFFFFFF), Color(0xFFF2D7DC)],
  );

  /// The softer pearl used on onboarding's Next pill.
  static const pearlSoftGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0xFFF4ECEE), Color(0xFFE3C7CE)],
  );

  /// Avatar fills, picked by name so a person keeps their colour.
  static const avatarGradients = [
    [Color(0xFFFF8A5B), Color(0xFFC2185B)],
    [Color(0xFF8E2DE2), Color(0xFF4A1F7A)],
    [Color(0xFF7A2E40), Color(0xFF3A1320)],
    [Color(0xFFFF8A5B), Color(0xFF8A3B2B)],
    [Color(0xFF4E2A5E), Color(0xFF24132E)],
  ];

  static List<Color> avatarFor(String name) =>
      avatarGradients[name.isEmpty ? 0 : name.codeUnits.fold<int>(0, (a, b) => a + b) % avatarGradients.length];
}

/// Font families bundled in assets/fonts.
abstract final class SakFont {
  static const body = 'Inter';
  static const display = 'InterTight';
  static const mono = 'JetBrainsMono';
}

/// The colour roles older code reads through `context.sak`. They map onto
/// the Ember palette; there is one appearance.
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

  static const ember = SakColors(
    background: Ember.ground,
    surface: Color(0xFF1A1214),
    surfaceRaised: Color(0xFF24171B),
    separator: Ember.hairline,
    ink: Ember.ink,
    inkSecondary: Ember.ink2,
    inkTertiary: Ember.ink3,
    accent: Ember.rose,
    onAccent: Ember.onPearl,
    accentSoft: Color(0x29F2A7B5),
    danger: Ember.emberStart,
    onDanger: Color(0xFFFFFFFF),
    dangerSoft: Color(0x388E1B32),
    success: Ember.sealed,
    successSoft: Color(0x265BD6A0),
    warning: Ember.attention,
    warningSoft: Color(0x1FF0B44C),
  );

  // Kept so callers written for two appearances still compile.
  static const light = ember;
  static const dark = ember;

  @override
  SakColors copyWith() => this;

  @override
  SakColors lerp(ThemeExtension<SakColors>? other, double t) => this;
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
  static const double control = 18;
  static const double group = 22;
  static const double card = 26;
  static const double sheet = 32;
  static const double pill = 999;
}

/// Monospace for hashes, IDs and recovery codes: they are read character
/// by character, so every glyph gets the same width.
abstract final class SakMono {
  static const String family = SakFont.mono;
  static const List<String> fallback = ['monospace', 'RobotoMono'];
}

/// Motion. Everything settles on a critically damped spring (no overshoot):
/// nothing here is thrown by a gesture, so nothing bounces.
abstract final class SakMotion {
  static const Duration quick = Duration(milliseconds: 180);
  static const Duration standard = Duration(milliseconds: 340);
  static const Duration slow = Duration(milliseconds: 600);

  static const Curve spring = _CriticalSpring();

  /// The canvas's cubic-bezier(.2,.9,.3,1), used for entrances.
  static const Curve enter = Cubic(0.2, 0.9, 0.3, 1);

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
  SakColors get sak => Theme.of(this).extension<SakColors>() ?? SakColors.ember;

  TextTheme get type => Theme.of(this).textTheme;
}
