import 'package:flutter/material.dart';
import 'core/app_services.dart';
import 'core/ai_service.dart';
import 'presentation/home_screen.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:justice_chain/core/pinata_service.dart'; // Adjust this path if needed


void main() async {
  // Required to ensure Flutter is ready before calling native code (Hive/Camera)
  WidgetsFlutterBinding.ensureInitialized();

  // Step 1: Initialize Hive and Logger (from your core folder)
  await AppServices.init();

  // Warm-load the TFLite model so the UI can report AI readiness early.
  // EmergencyController registers the actual distress callback after the camera
  // is initialized in home_screen.dart.
  await AIService.instance.initModel();
  await dotenv.load(fileName: ".env");
  runApp(const JusticeChainApp());
}

class JusticeChainApp extends StatelessWidget {
  const JusticeChainApp({super.key});

  Future<void> testPinataUpload() async {
  try {
    print('1. Creating a secure dummy file...');
    // Find a safe temporary folder on the phone
    final directory = await getTemporaryDirectory();
    final testFilePath = '${directory.path}/test_evidence.txt';

    // Create a text file with a secret message
    final file = File(testFilePath);
    await file.writeAsString('This is a test distress signal for Justice-Chain. The vault is secure!');

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
      debugShowCheckedModeBanner: false,
      title: 'Justice-Chain',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.red),
        useMaterial3: true,
      ),
      // We wrap your Home Screen in a Scaffold just to inject our test button!
      home: Scaffold(
        body: const MainSafetyScreen(),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: testPinataUpload,
          icon: const Icon(Icons.cloud_upload),
          label: const Text('Test IPFS'),
          backgroundColor: Colors.blue,
        ),
      ),
    );
  }
}
