import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../core/identity_service.dart';

class GuardianPairingScreen extends StatefulWidget {
  const GuardianPairingScreen({super.key});

  @override
  State<GuardianPairingScreen> createState() => _GuardianPairingScreenState();
}

class _GuardianPairingScreenState extends State<GuardianPairingScreen> {
  String? _qrPayload;
  String? _nodeId;

  @override
  void initState() {
    super.initState();
    _loadIdentity();
  }

  Future<void> _loadIdentity() async {
    final payload = await IdentityService.getQrPayload();
    final id = await IdentityService.getMyNodeId();
    setState(() {
      _qrPayload = payload;
      _nodeId = id;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Add Guardian'),
        backgroundColor: Colors.black87,
      ),
      body: Center(
        child: _qrPayload == null
            ? const CircularProgressIndicator()
            : Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text(
                    'Your Secure Node ID',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade200,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: SelectableText(
                      _nodeId ?? '',
                      style: const TextStyle(
                        fontSize: 24, 
                        fontWeight: FontWeight.w900, 
                        letterSpacing: 2.0
                      ),
                    ),
                  ),
                  const SizedBox(height: 40),
                  const Text(
                    'Have a trusted Guardian scan this code',
                    style: TextStyle(color: Colors.grey),
                  ),
                  const SizedBox(height: 20),
                  // Render the QR Code
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: const [
                        BoxShadow(
                          color: Colors.black12,
                          blurRadius: 10,
                          spreadRadius: 2,
                        )
                      ],
                    ),
                    child: QrImageView(
                      data: _qrPayload!,
                      version: QrVersions.auto,
                      size: 250.0,
                      backgroundColor: Colors.white,
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}