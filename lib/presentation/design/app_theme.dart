import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'tokens.dart';

/// The Dark Ember theme. [brightness] is accepted for older callers; the
/// app has one appearance.
ThemeData buildSakTheme([Brightness brightness = Brightness.dark]) {
  const c = SakColors.ember;

  const scheme = ColorScheme(
    brightness: Brightness.dark,
    primary: Ember.rose,
    onPrimary: Ember.onPearl,
    primaryContainer: Color(0xFF3D1C24),
    onPrimaryContainer: Ember.ink,
    secondary: Ember.rose,
    onSecondary: Ember.onPearl,
    error: Ember.alertText,
    onError: Color(0xFFFFFFFF),
    surface: Color(0xFF1A1214),
    onSurface: Ember.ink,
    onSurfaceVariant: Ember.ink2,
    surfaceContainerLowest: Ember.ground,
    surfaceContainerLow: Color(0xFF1A1214),
    surfaceContainer: Color(0xFF1E1518),
    surfaceContainerHigh: Color(0xFF24171B),
    surfaceContainerHighest: Color(0xFF2A1C20),
    outline: Ember.ink3,
    outlineVariant: Ember.hairline,
  );

  TextStyle body(double size, double height, FontWeight w, {Color color = Ember.ink, double spacing = 0}) =>
      TextStyle(fontFamily: SakFont.body, fontSize: size, height: height / size, fontWeight: w, letterSpacing: spacing, color: color);
  TextStyle display(double size, double height, double spacing) => TextStyle(
        fontFamily: SakFont.display,
        fontSize: size,
        height: height / size,
        fontWeight: FontWeight.w700,
        letterSpacing: spacing,
        color: Ember.ink,
      );

  // The canvas's scale: hero 42, large title 34, title 22, headline 17,
  // body 15–17, footnote 13, caption 12.
  final textTheme = TextTheme(
    displayLarge: display(42, 46, -1.1),
    displayMedium: display(34, 38, -0.8),
    displaySmall: display(32, 36, -0.8),
    headlineMedium: display(28, 32, -0.6),
    headlineSmall: display(22, 27, -0.3),
    titleLarge: body(20, 25, FontWeight.w600),
    titleMedium: body(17, 22, FontWeight.w600),
    titleSmall: body(15, 20, FontWeight.w600),
    bodyLarge: body(16, 22, FontWeight.w400),
    bodyMedium: body(15, 21, FontWeight.w400),
    bodySmall: body(13, 18, FontWeight.w400, color: Ember.ink2),
    labelLarge: body(17, 22, FontWeight.w700),
    labelMedium: body(13, 18, FontWeight.w600, color: Ember.ink2),
    labelSmall: body(12, 16, FontWeight.w500, color: Ember.ink2),
  );

  OutlineInputBorder fieldBorder(Color color, [double width = 1]) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(SakRadius.control),
        borderSide: BorderSide(color: color, width: width),
      );

  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    fontFamily: SakFont.body,
    colorScheme: scheme,
    scaffoldBackgroundColor: Ember.ground,
    canvasColor: Ember.ground,
    textTheme: textTheme,
    extensions: const [c],
    splashFactory: NoSplash.splashFactory, // press feedback is a scale, not a ripple
    highlightColor: const Color(0x0FFFFFFF),
    // Slide-in pages that can be swiped back from the edge, interruptibly.
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: CupertinoPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
      },
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      foregroundColor: Ember.ink,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: true,
      titleTextStyle: textTheme.titleMedium,
      systemOverlayStyle: SystemUiOverlayStyle.light,
    ),
    iconTheme: const IconThemeData(color: Ember.ink, size: 22),
    dividerTheme: const DividerThemeData(color: Ember.hairline, thickness: 1, space: 1),
    textSelectionTheme: const TextSelectionThemeData(
      cursorColor: Ember.rose,
      selectionColor: Color(0x55F2A7B5),
      selectionHandleColor: Ember.rose,
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: Ember.rose,
        minimumSize: const Size(44, 44),
        textStyle: textTheme.titleSmall,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: Ember.ink,
        foregroundColor: Ember.onPearl,
        minimumSize: const Size(64, 48),
        shape: const StadiumBorder(),
        textStyle: textTheme.titleSmall,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Ember.glass,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      labelStyle: textTheme.bodyLarge?.copyWith(color: Ember.ink2),
      floatingLabelStyle: textTheme.bodyMedium?.copyWith(color: Ember.rose, fontWeight: FontWeight.w600),
      hintStyle: textTheme.bodyMedium?.copyWith(color: Ember.ink3),
      errorStyle: textTheme.bodySmall?.copyWith(color: Ember.alertText),
      border: fieldBorder(const Color(0x24FFFFFF)),
      enabledBorder: fieldBorder(const Color(0x24FFFFFF)),
      focusedBorder: fieldBorder(Ember.rose, 1.5),
      errorBorder: fieldBorder(Ember.alertText),
      focusedErrorBorder: fieldBorder(Ember.alertText, 1.5),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: const Color(0xFF221A1D),
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(SakRadius.card),
        side: const BorderSide(color: Ember.glassBorder),
      ),
      titleTextStyle: textTheme.titleLarge,
      contentTextStyle: textTheme.bodyMedium?.copyWith(color: Ember.ink2),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      modalBarrierColor: Color(0x8C000000),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: const Color(0xFF2A1C20),
      contentTextStyle: textTheme.bodyMedium,
      actionTextColor: Ember.rose,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(SakRadius.control),
        side: const BorderSide(color: Ember.glassBorder),
      ),
      insetPadding: const EdgeInsets.fromLTRB(SakSpace.lg, 0, SakSpace.lg, SakSpace.lg),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: Ember.rose,
      linearTrackColor: Color(0x1AFFFFFF),
      circularTrackColor: Color(0x1AFFFFFF),
    ),
    cupertinoOverrideTheme: const CupertinoThemeData(primaryColor: Ember.rose, brightness: Brightness.dark),
  );
}
