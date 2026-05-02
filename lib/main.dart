import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  runApp(const JusticeChainApp());
}

class JusticeChainApp extends StatelessWidget {
  const JusticeChainApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Justice-Chain',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.red), // Emergency theme
        useMaterial3: true,
      ),
      home: const MainSafetyScreen(),
    );
  }
}

class MainSafetyScreen extends StatefulWidget {
  const MainSafetyScreen({super.key});

  @override
  State<MainSafetyScreen> createState() => _MainSafetyScreenState();
}

class _MainSafetyScreenState extends State<MainSafetyScreen> {
  String _statusMessage = "Checking Permissions...";

  @override
  void initState() {
    super.initState();
    // Step 1: Request permissions immediately when the app starts
    _initPermissions();
  }

  Future<void> _initPermissions() async {
    // This is your logic integrated into the UI
    Map<Permission, PermissionStatus> statuses = await [
      Permission.camera,
      Permission.microphone,
      Permission.storage,
      Permission.location, // Added location as per your PRD
    ].request();

    if (statuses[Permission.camera]!.isGranted && 
        statuses[Permission.microphone]!.isGranted) {
      setState(() {
        _statusMessage = "System Ready: Monitoring Active";
      });
    } else {
      setState(() {
        _statusMessage = "System Error: Permissions Denied";
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Justice-Chain Sentinel"),
        backgroundColor: Colors.red.shade100,
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.security, size: 80, color: Colors.red),
            const SizedBox(height: 20),
            Text(
              _statusMessage,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 40),
            ElevatedButton(
              onPressed: _initPermissions, 
              child: const Text("Re-check Permissions"),
            )
          ],
        ),
      ),
    );
  }
}

/*App starts →
initState() runs →
Permissions requested →
If granted → System Ready
Else → Error message*/

/*This file initializes the app and ensures all critical permissions like camera and microphone are granted before enabling the core functionality. 
It uses a StatefulWidget to dynamically update the UI based on permission status.
 The initState method triggers permission requests at startup, and depending on the result, the system either enters monitoring mode or shows an error.”*/