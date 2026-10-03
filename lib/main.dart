import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'core/ai_service.dart';
import 'core/identity_service.dart';
import 'core/app_services.dart';
import 'presentation/home_screen.dart';
import 'presentation/registration_screen.dart';

import 'package:flutter_dotenv/flutter_dotenv.dart';

import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:justice_chain/core/pinata_service.dart'; // Adjust this path if needed

void main() async {
  // Fixes the isolate crash
  WidgetsFlutterBinding.ensureInitialized();

  await AppServices.init();
  
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
  await dotenv.load(fileName: ".env");

  runApp(JusticeChainApp(isRegistered: isRegistered));
}

class JusticeChainApp extends StatelessWidget {
  final bool isRegistered;

  const JusticeChainApp({super.key, required this.isRegistered});

  Future<void> testPinataUpload() async {
    try {
      print('1. Creating a secure dummy file...');
      // Find a safe temporary folder on the phone
      final directory = await getTemporaryDirectory();
      final testFilePath = '${directory.path}/test_evidence.txt';

      // Create a text file with a secret message
      final file = File(testFilePath);
      await file.writeAsString(
        'This is a test distress signal for Justice-Chain. The vault is secure!',
      );

      print('2. Sending to IPFS...');
      // Call the service we just built!
      String? cid = await PinataService.uploadToIPFS(testFilePath);

      if (cid != null) {
        print('🎉 SUCCESS! Your file is on the decentralized web.');
        print('🌐 View it here: https://ipfs.io/ipfs/$cid');
      } else {
        print('❌ Upload failed. Check your Pinata keys.');
      }
    } catch (e) {
      print('❌ Error during test: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Justice-Chain',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.red,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: isRegistered
          ? Scaffold(
              body: const MainSafetyScreen(),
              // Debug-only IPFS smoke test. Never ship this in a release
              // build: it's an unauthenticated upload trigger with no
              // relation to the emergency flow.
              floatingActionButton: kDebugMode
                  ? FloatingActionButton.extended(
                      onPressed: testPinataUpload,
                      icon: const Icon(Icons.cloud_upload),
                      label: const Text('Test IPFS'),
                      backgroundColor: Colors.blue,
                    )
                  : null,
            )
          : const RegistrationScreen(),
    );
  }
}
