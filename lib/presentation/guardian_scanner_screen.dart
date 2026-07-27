import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../logic/guardian_manager.dart';
import 'dart:developer' as developer;

class GuardianScannerScreen extends StatefulWidget {
  const GuardianScannerScreen({super.key});

  @override
  State<GuardianScannerScreen> createState() => _GuardianScannerScreenState();
}

class _GuardianScannerScreenState extends State<GuardianScannerScreen> {
  bool _isProcessing = false;

  void _onDetect(BarcodeCapture capture) {
    if (_isProcessing) return; // Prevent scanning the same code 100 times a second
    
    final List<Barcode> barcodes = capture.barcodes;
    if (barcodes.isEmpty || barcodes.first.rawValue == null) return;

    final String code = barcodes.first.rawValue!;
    
    try {
      // Decode the JSON payload you generated in the previous step
      final data = jsonDecode(code);
      
      if (data.containsKey('node_id') && data.containsKey('public_key')) {
        setState(() {
          _isProcessing = true; // Lock scanner
        });
        
        final nodeId = data['node_id'];
        final publicKey = data['public_key'];
        
        _promptForName(nodeId, publicKey);
      }
    } catch (e) {
      // Ignore normal text QR codes
      developer.log('Invalid QR scanned', error: e);
    }
  }

  Future<void> _promptForName(String nodeId, String publicKey) async {
    String guardianName = '';
    
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return AlertDialog(
          title: const Text('Add Trusted Guardian'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Secure Node ID:\n$nodeId', style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.grey)),
              const SizedBox(height: 16),
              const Text('Enter a name for this device (e.g. Mom, Alex):'),
              TextField(
                onChanged: (val) => guardianName = val,
                decoration: const InputDecoration(hintText: "Guardian Name"),
                autofocus: true,
              )
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                setState(() => _isProcessing = false); // Unlock scanner
              },
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () async {
                if (guardianName.trim().isEmpty) return;
                
                // Save to Hive
                await GuardianManager.addGuardian(
                  nodeId: nodeId,
                  publicKey: publicKey,
                  name: guardianName.trim(),
                );
                
                if (mounted) {
                  Navigator.pop(context); // Close dialog
                  Navigator.pop(context); // Return to Home Screen
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('🛡️ ${guardianName.trim()} is now a Trusted Guardian!')),
                  );
                }
              },
              child: const Text('Save'),
            )
          ],
        );
      }
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan Guardian QR'),
        backgroundColor: Colors.black87,
        foregroundColor: Colors.white,
      ),
      body: MobileScanner(
        onDetect: _onDetect,
      ),
    );
  }
}