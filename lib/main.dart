import 'package:flutter/material.dart';
import 'core/app_services.dart';
import 'presentation/home_screen.dart';

void main() async {
  // Required to ensure Flutter is ready before calling native code (Hive/Camera)
  WidgetsFlutterBinding.ensureInitialized();

  // Step 1: Initialize Hive and Logger (from your core folder)
  await AppServices.init();

  runApp(const JusticeChainApp());
}

class JusticeChainApp extends StatelessWidget {
  const JusticeChainApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Justice-Chain',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.red),
        useMaterial3: true,
      ),
      // We point to our new structured Home Screen
      home: const MainSafetyScreen(),
    );
  }
}