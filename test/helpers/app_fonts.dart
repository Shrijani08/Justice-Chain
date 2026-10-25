import 'package:flutter/services.dart';

/// Loads the bundled Dark Ember fonts, so widget tests lay text out with
/// the real glyph widths instead of the test font's squares.
Future<void> loadAppFonts() async {
  const families = {
    'Inter': ['Inter-400', 'Inter-500', 'Inter-600', 'Inter-700'],
    'InterTight': ['InterTight-600', 'InterTight-700'],
    'JetBrainsMono': ['JetBrainsMono-400', 'JetBrainsMono-500'],
  };
  for (final entry in families.entries) {
    final loader = FontLoader(entry.key);
    for (final file in entry.value) {
      loader.addFont(rootBundle.load('assets/fonts/$file.ttf'));
    }
    await loader.load();
  }
}
