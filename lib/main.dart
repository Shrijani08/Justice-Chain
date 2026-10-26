import 'package:flutter/material.dart';
import 'core/ai_service.dart';
import 'core/identity_service.dart';
import 'core/app_services.dart';
import 'core/disguise_service.dart';
import 'core/evidence_lock.dart';
import 'core/protection_service.dart';
import 'presentation/design/app_theme.dart';
import 'presentation/disguise_gate.dart';
import 'presentation/home_screen.dart';
import 'presentation/onboarding_screen.dart';

import 'package:flutter_dotenv/flutter_dotenv.dart';

void main() async {
  // Fixes the isolate crash
  WidgetsFlutterBinding.ensureInitialized();

  await AppServices.init();
  await DisguiseService.init();
  await ProtectionService.init();

  // Check if the user is already registered before loading the UI
  bool isRegistered = false;
  try {
    isRegistered = await IdentityService.isRegistered();
  } catch (e) {
    debugPrint('Registration check failed: $e');
  }

  // Warm-load the TFLite model so the UI can report AI readiness early.
  // EmergencyController registers the actual distress callback after the camera
  // is initialized in home_screen.dart.
  await AIService.instance.initModel();
  // Non-secret settings only (config/app.env); secrets never ship in the APK.
  await dotenv.load(fileName: "config/app.env");
  await AppServices.startBackgroundWork();
  EvidenceLock.lockWhenAppLeaves();

  runApp(JusticeChainApp(isRegistered: isRegistered));
}

class JusticeChainApp extends StatelessWidget {
  final bool isRegistered;

  const JusticeChainApp({super.key, required this.isRegistered});

  @override
  Widget build(BuildContext context) {
    // In disguise mode the recent-apps list shows "Calculator" too.
    return ValueListenableBuilder<bool>(
      valueListenable: DisguiseService.enabled,
      builder: (context, disguised, _) => _app(disguised ? 'Calculator' : 'Sakshya'),
    );
  }

  Widget _app(String title) {
    return MaterialApp(
      title: title,
      debugShowCheckedModeBanner: false,
      // Dark Ember is the one appearance.
      theme: buildSakTheme(),
      themeMode: ThemeMode.dark,
      home: isRegistered ? const MainSafetyScreen() : const OnboardingScreen(),
      builder: (context, child) => isRegistered ? DisguiseGate(child: child!) : child!,
    );
  }
}
