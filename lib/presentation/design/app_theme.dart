import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'tokens.dart';

/// Builds the app theme for one appearance. Light and dark follow the
/// system setting; there is no in-app switch.
ThemeData buildSakTheme(Brightness brightness) {
  final c = brightness == Brightness.dark ? SakColors.dark : SakColors.light;
  final isDark = brightness == Brightness.dark;

  final scheme = ColorScheme(
    brightness: brightness,
    primary: c.accent,
    onPrimary: c.onAccent,
    primaryContainer: c.accentSoft,
    onPrimaryContainer: c.ink,
    secondary: c.accent,
    onSecondary: c.onAccent,
    secondaryContainer: c.accentSoft,
    onSecondaryContainer: c.ink,
    error: c.danger,
    onError: c.onDanger,
    errorContainer: c.dangerSoft,
    onErrorContainer: c.ink,
    surface: c.surface,
    onSurface: c.ink,
    onSurfaceVariant: c.inkSecondary,
    surfaceContainerLowest: c.background,
    surfaceContainerLow: c.surface,
    surfaceContainer: c.surface,
    surfaceContainerHigh: c.surfaceRaised,
    surfaceContainerHighest: c.surfaceRaised,
    outline: c.inkTertiary,
    outlineVariant: c.separator,
  );

  // Size-specific tracking: tighter as text grows, slightly open when small.
  final textTheme = TextTheme(
    displaySmall: TextStyle(fontSize: 34, height: 41 / 34, fontWeight: FontWeight.w700, letterSpacing: -0.6, color: c.ink),
    headlineMedium: TextStyle(fontSize: 28, height: 34 / 28, fontWeight: FontWeight.w700, letterSpacing: -0.4, color: c.ink),
    headlineSmall: TextStyle(fontSize: 24, height: 30 / 24, fontWeight: FontWeight.w700, letterSpacing: -0.3, color: c.ink),
    titleLarge: TextStyle(fontSize: 20, height: 25 / 20, fontWeight: FontWeight.w600, letterSpacing: -0.2, color: c.ink),
    titleMedium: TextStyle(fontSize: 17, height: 22 / 17, fontWeight: FontWeight.w600, letterSpacing: -0.2, color: c.ink),
    titleSmall: TextStyle(fontSize: 15, height: 20 / 15, fontWeight: FontWeight.w600, letterSpacing: -0.1, color: c.ink),
    bodyLarge: TextStyle(fontSize: 17, height: 23 / 17, fontWeight: FontWeight.w400, letterSpacing: -0.2, color: c.ink),
    bodyMedium: TextStyle(fontSize: 15, height: 21 / 15, fontWeight: FontWeight.w400, letterSpacing: -0.1, color: c.ink),
    bodySmall: TextStyle(fontSize: 13, height: 18 / 13, fontWeight: FontWeight.w400, letterSpacing: 0, color: c.inkSecondary),
    labelLarge: TextStyle(fontSize: 17, height: 22 / 17, fontWeight: FontWeight.w600, letterSpacing: -0.2, color: c.ink),
    labelMedium: TextStyle(fontSize: 13, height: 18 / 13, fontWeight: FontWeight.w600, letterSpacing: 0, color: c.inkSecondary),
    labelSmall: TextStyle(fontSize: 12, height: 16 / 12, fontWeight: FontWeight.w500, letterSpacing: 0.2, color: c.inkSecondary),
  );

  final controlShape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(SakRadius.control));
  const controlPadding = EdgeInsets.symmetric(horizontal: 20, vertical: 16);
  const controlSize = Size(64, 52);

  OutlineInputBorder fieldBorder(Color color, [double width = 1]) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(SakRadius.control),
        borderSide: BorderSide(color: color, width: width),
      );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: c.background,
    canvasColor: c.background,
    textTheme: textTheme,
    extensions: [c],
    splashFactory: NoSplash.splashFactory, // press feedback is a scale + tint, not a ripple
    highlightColor: c.ink.withValues(alpha: 0.06),
    // Slide-in pages that can be swiped back from the edge, interruptibly.
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: CupertinoPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
      },
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: c.background,
      foregroundColor: c.ink,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: true,
      titleTextStyle: textTheme.titleMedium,
      systemOverlayStyle: isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
    ),
    iconTheme: IconThemeData(color: c.ink, size: 22),
    dividerTheme: DividerThemeData(color: c.separator, thickness: 0.5, space: 0.5),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: c.accent,
        foregroundColor: c.onAccent,
        minimumSize: controlSize,
        padding: controlPadding,
        shape: controlShape,
        textStyle: textTheme.labelLarge,
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: c.accent,
        foregroundColor: c.onAccent,
        elevation: 0,
        minimumSize: controlSize,
        padding: controlPadding,
        shape: controlShape,
        textStyle: textTheme.labelLarge,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: c.accent,
        minimumSize: controlSize,
        padding: controlPadding,
        shape: controlShape,
        side: BorderSide(color: c.separator),
        textStyle: textTheme.labelLarge,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: c.accent,
        minimumSize: const Size(44, 44),
        shape: controlShape,
        textStyle: textTheme.titleSmall,
      ),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: c.surfaceRaised,
      foregroundColor: c.ink,
      elevation: 2,
      shape: const StadiumBorder(),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: c.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      labelStyle: textTheme.bodyLarge?.copyWith(color: c.inkSecondary),
      floatingLabelStyle: textTheme.bodyMedium?.copyWith(color: c.accent, fontWeight: FontWeight.w600),
      hintStyle: textTheme.bodyLarge?.copyWith(color: c.inkTertiary),
      prefixIconColor: c.inkSecondary,
      errorStyle: textTheme.bodySmall?.copyWith(color: c.danger),
      border: fieldBorder(c.separator),
      enabledBorder: fieldBorder(c.separator),
      focusedBorder: fieldBorder(c.accent, 2),
      errorBorder: fieldBorder(c.danger),
      focusedErrorBorder: fieldBorder(c.danger, 2),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.all(Colors.white),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected) ? c.success : c.separator,
      ),
      trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: c.inkSecondary,
      textColor: c.ink,
      titleTextStyle: textTheme.bodyLarge,
      subtitleTextStyle: textTheme.bodySmall,
      contentPadding: const EdgeInsets.symmetric(horizontal: SakSpace.lg),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: c.surfaceRaised,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(SakRadius.sheet)),
      titleTextStyle: textTheme.titleLarge,
      contentTextStyle: textTheme.bodyMedium?.copyWith(color: c.inkSecondary),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: c.surfaceRaised,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(SakRadius.control)),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: isDark ? c.surfaceRaised : c.ink,
      contentTextStyle: textTheme.bodyMedium?.copyWith(color: isDark ? c.ink : c.surface),
      actionTextColor: c.accentSoft,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(SakRadius.control)),
      insetPadding: const EdgeInsets.fromLTRB(SakSpace.lg, 0, SakSpace.lg, SakSpace.lg),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: c.accent,
      linearTrackColor: c.separator,
    ),
    cupertinoOverrideTheme: CupertinoThemeData(primaryColor: c.accent, brightness: brightness),
  );
}
