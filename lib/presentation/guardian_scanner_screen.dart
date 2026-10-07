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
        final x25519PublicKey = data['x25519_public_key'] as String?;
        final anchoringAddress = data['anchoring_address'] as String?;

        _promptForName(nodeId, publicKey, x25519PublicKey, anchoringAddress);
      }
    } catch (e) {
      // Ignore normal text QR codes
      developer.log('Invalid QR scanned', error: e);
    }
  }

  Future<void> _promptForName(
    String nodeId,
    String publicKey,
    String? x25519PublicKey,
    String? anchoringAddress,
  ) async {
    String guardianName = '';

    // The dialog only collects the name; saving and navigation happen below
    // with this screen's context, which is still valid after the dialog closes.
    final name = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
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
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                if (guardianName.trim().isEmpty) return;
                Navigator.pop(dialogContext, guardianName.trim());
              },
              child: const Text('Save'),
            )
          ],
        );
      }
    );

    if (!mounted) return;
    if (name == null) {
      setState(() => _isProcessing = false); // Cancelled: unlock scanner
      return;
    }

    final messenger = ScaffoldMessenger.of(context);
    try {
      // Save to Hive
      await GuardianManager.addGuardian(
        nodeId: nodeId,
        publicKey: publicKey,
        name: name,
        x25519PublicKey: x25519PublicKey,
        anchoringAddress: anchoringAddress,
      );
    } catch (e) {
      developer.log('Failed to save guardian', error: e);
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not save guardian. Please scan again.')),
      );
      if (mounted) setState(() => _isProcessing = false);
      return;
    }

    // The messenger is app-wide, so the snackbar stays visible on the Home Screen.
    messenger.showSnackBar(
      SnackBar(content: Text('🛡️ $name is now a Trusted Guardian!')),
    );
    if (mounted) Navigator.pop(context); // Return to Home Screen
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