import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../logic/guardian_manager.dart';
import 'design/components.dart';
import 'design/tokens.dart';
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
              Text('Secure Node ID', style: Theme.of(dialogContext).textTheme.labelMedium),
              const SizedBox(height: 4),
              MonoText(nodeId, selectable: true),
              const SizedBox(height: 20),
              TextField(
                onChanged: (val) => guardianName = val,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'Guardian Name',
                  hintText: 'e.g. Mom, Alex',
                ),
                autofocus: true,
              )
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(88, 44)),
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
      SnackBar(content: Text('$name is now a trusted guardian.')),
    );
    if (mounted) Navigator.pop(context); // Return to Home Screen
  }

  @override
  Widget build(BuildContext context) {
    const c = SakColors.dark;
    return Theme(
      data: Theme.of(context).copyWith(
        appBarTheme: Theme.of(context).appBarTheme.copyWith(
              backgroundColor: Colors.black,
              foregroundColor: c.ink,
              titleTextStyle: context.type.titleMedium?.copyWith(color: c.ink),
            ),
      ),
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(title: const Text('Scan Guardian QR')),
        body: Stack(
          fit: StackFit.expand,
          children: [
            MobileScanner(
              onDetect: _onDetect,
            ),
            const IgnorePointer(child: CustomPaint(painter: _Viewfinder())),
            Positioned(
              left: SakSpace.xl,
              right: SakSpace.xl,
              bottom: SakSpace.xxl,
              child: SafeArea(
                top: false,
                child: Center(
                  child: AnimatedSwitcher(
                    duration: SakMotion.of(context, SakMotion.quick),
                    child: Container(
                      key: ValueKey(_isProcessing),
                      padding: const EdgeInsets.symmetric(horizontal: SakSpace.lg, vertical: SakSpace.md),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.72),
                        borderRadius: BorderRadius.circular(100),
                      ),
                      child: Text(
                        _isProcessing ? 'Code found' : "Point at the QR on your guardian's phone",
                        textAlign: TextAlign.center,
                        style: context.type.bodyMedium?.copyWith(color: Colors.white),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Dims everything but a centred square and marks its corners.
class _Viewfinder extends CustomPainter {
  const _Viewfinder();

  @override
  void paint(Canvas canvas, Size size) {
    final side = size.shortestSide * 0.68;
    final window = Rect.fromCenter(center: size.center(Offset.zero), width: side, height: side);
    final rrect = RRect.fromRectAndRadius(window, const Radius.circular(SakRadius.sheet));

    canvas.drawPath(
      Path.combine(
        PathOperation.difference,
        Path()..addRect(Offset.zero & size),
        Path()..addRRect(rrect),
      ),
      Paint()..color = Colors.black.withValues(alpha: 0.5),
    );

    final corner = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    const len = 28.0;
    const r = SakRadius.sheet;
    for (final (dx, dy) in const [(0, 0), (1, 0), (0, 1), (1, 1)]) {
      final x = dx == 0 ? window.left : window.right;
      final y = dy == 0 ? window.top : window.bottom;
      final sx = dx == 0 ? 1.0 : -1.0;
      final sy = dy == 0 ? 1.0 : -1.0;
      final path = Path()
        ..moveTo(x, y + sy * (r + len))
        ..lineTo(x, y + sy * r)
        ..arcToPoint(Offset(x + sx * r, y), radius: const Radius.circular(r), clockwise: sx == sy)
        ..lineTo(x + sx * (r + len), y);
      canvas.drawPath(path, corner);
    }
  }

  @override
  bool shouldRepaint(_Viewfinder old) => false;
}
