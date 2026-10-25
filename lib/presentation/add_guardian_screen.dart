import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../core/device_link_service.dart';
import '../core/identity_service.dart';
import '../logic/guardian_manager.dart';
import 'design/components.dart';
import 'design/tokens.dart';

/// Pairing in both directions: scan a guardian's QR, or show yours.
/// Open it through SafetyActions.addGuardian, which frees the camera.
class AddGuardianScreen extends StatefulWidget {
  const AddGuardianScreen({super.key, this.showMine = false});
  final bool showMine;

  @override
  State<AddGuardianScreen> createState() => _AddGuardianScreenState();
}

class _AddGuardianScreenState extends State<AddGuardianScreen> {
  late int _tab = widget.showMine ? 1 : 0;

  @override
  Widget build(BuildContext context) {
    return EmberScaffold(
      glows: const [
        Glow(color: Color(0xFF8A3B2B), width: 400, height: 320, opacity: 0.6, right: -140, top: -80),
        Glow(color: Ember.wineGlow, width: 300, height: 300, left: -120, bottom: 40),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SakTopBar(title: 'Add guardian'),
          const SizedBox(height: 18),
          SakSegmented(options: const ['Scan their QR', 'Show my QR'], index: _tab, onChanged: (i) => setState(() => _tab = i)),
          const SizedBox(height: 18),
          Expanded(
            child: AnimatedSwitcher(
              duration: SakMotion.of(context, const Duration(milliseconds: 300)),
              child: _tab == 0 ? const _Scan(key: ValueKey('scan')) : const _Mine(key: ValueKey('mine')),
            ),
          ),
        ],
      ),
    );
  }
}

class _Scan extends StatefulWidget {
  const _Scan({super.key});

  @override
  State<_Scan> createState() => _ScanState();
}

class _ScanState extends State<_Scan> with SingleTickerProviderStateMixin {
  bool _isProcessing = false;
  late final AnimationController _sweep = AnimationController(vsync: this, duration: const Duration(milliseconds: 2400));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!SakMotion.reduced(context) && !_sweep.isAnimating) _sweep.repeat();
  }

  @override
  void dispose() {
    _sweep.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_isProcessing) return; // the same code arrives many times a second

    final barcodes = capture.barcodes;
    if (barcodes.isEmpty || barcodes.first.rawValue == null) return;

    try {
      final data = jsonDecode(barcodes.first.rawValue!);
      if (DeviceLinkService.isDeviceQr(data)) {
        setState(() => _isProcessing = true);
        _confirmLinkDevice(data as Map);
      } else if (data is Map && data.containsKey('node_id') && data.containsKey('public_key')) {
        setState(() => _isProcessing = true);
        _promptForName(
          data['node_id'] as String,
          data['public_key'] as String,
          data['x25519_public_key'] as String?,
          data['anchoring_address'] as String?,
        );
      }
    } catch (e) {
      // Ordinary text QR codes are ignored.
      developer.log('Invalid QR scanned', error: e);
    }
  }

  /// An SOS device's QR: link it to this user instead of adding a guardian.
  Future<void> _confirmLinkDevice(Map qr) async {
    final nodeId = qr['node_id'] as String? ?? '';
    final link = await showSakSheet<bool>(
      context,
      (sheetContext) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Link this SOS device?', style: sheetContext.type.headlineSmall),
          const SizedBox(height: 6),
          MonoText('Device ${nodeId.length > 8 ? '${nodeId.substring(0, 4)}…${nodeId.substring(nodeId.length - 4)}' : nodeId}', style: const TextStyle(fontSize: 12, color: Ember.ink2)),
          const SizedBox(height: 12),
          Text(
            'Its recordings will be yours, and your guardians will get their key pieces. '
            'It picks up your guardian list within a minute.',
            style: sheetContext.type.bodyMedium?.copyWith(fontSize: 14, color: const Color(0xB3F4ECEE)),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: SakButton(label: 'Cancel', style: SakButtonStyle.glass, height: 54, fontSize: 16, onPressed: () => Navigator.pop(sheetContext, false)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: SakButton(label: 'Link', style: SakButtonStyle.pearl, height: 54, fontSize: 16, onPressed: () => Navigator.pop(sheetContext, true)),
              ),
            ],
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (link != true) {
      setState(() => _isProcessing = false);
      return;
    }

    final messenger = ScaffoldMessenger.of(context);
    try {
      await DeviceLinkService.link(qr);
    } catch (e) {
      developer.log('Linking the SOS device failed', error: e);
      messenger.showSnackBar(SnackBar(
        content: Text(e is ArgumentError ? '${e.message}' : 'Could not reach the server to link the device. Check your internet and scan again.'),
      ));
      if (mounted) setState(() => _isProcessing = false);
      return;
    }
    messenger.showSnackBar(const SnackBar(content: Text('SOS device linked. Its light turns solid within a minute.')));
    if (mounted) Navigator.pop(context);
  }

  Future<void> _promptForName(String nodeId, String publicKey, String? x25519PublicKey, String? anchoringAddress) async {
    final controller = TextEditingController();
    final name = await showSakSheet<String>(
      context,
      (sheetContext) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Name this guardian', style: sheetContext.type.headlineSmall),
          const SizedBox(height: 6),
          MonoText('ID ${nodeId.length > 8 ? '${nodeId.substring(0, 4)}…${nodeId.substring(nodeId.length - 4)}' : nodeId}', style: const TextStyle(fontSize: 12, color: Ember.ink2)),
          const SizedBox(height: 18),
          const FieldLabel('Name'),
          TextField(
            controller: controller,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            decoration: sakField(hint: 'e.g. Mom, Alex'),
            onSubmitted: (v) {
              if (v.trim().isNotEmpty) Navigator.pop(sheetContext, v.trim());
            },
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: SakButton(label: 'Cancel', style: SakButtonStyle.glass, height: 54, fontSize: 16, onPressed: () => Navigator.pop(sheetContext)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: SakButton(
                  label: 'Save',
                  style: SakButtonStyle.pearl,
                  height: 54,
                  fontSize: 16,
                  onPressed: () {
                    if (controller.text.trim().isNotEmpty) Navigator.pop(sheetContext, controller.text.trim());
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
    controller.dispose();

    if (!mounted) return;
    if (name == null) {
      setState(() => _isProcessing = false); // cancelled: scan again
      return;
    }

    final messenger = ScaffoldMessenger.of(context);
    try {
      await GuardianManager.addGuardian(
        nodeId: nodeId,
        publicKey: publicKey,
        name: name,
        x25519PublicKey: x25519PublicKey,
        anchoringAddress: anchoringAddress,
      );
    } catch (e) {
      developer.log('Failed to save guardian', error: e);
      messenger.showSnackBar(const SnackBar(content: Text('Could not save guardian. Please scan again.')));
      if (mounted) setState(() => _isProcessing = false);
      return;
    }

    // The messenger is app-wide, so the snackbar stays up after this closes.
    messenger.showSnackBar(SnackBar(content: Text('$name is now a trusted guardian.')));
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(28),
            child: Stack(
              fit: StackFit.expand,
              children: [
                const ColoredBox(color: Color(0xFF120C0E)),
                MobileScanner(onDetect: _onDetect),
                IgnorePointer(
                  child: AnimatedBuilder(
                    animation: _sweep,
                    builder: (context, _) => CustomPaint(painter: _Viewfinder(sweep: _sweep.value, found: _isProcessing)),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          _isProcessing ? 'Code found' : "Point at the QR on your guardian's phone.\nYou'll name them next.",
          textAlign: TextAlign.center,
          style: context.type.bodyMedium?.copyWith(color: const Color(0xBFF4ECEE)),
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}

/// Dims all but a centred square, marks its corners and sweeps a line.
class _Viewfinder extends CustomPainter {
  const _Viewfinder({required this.sweep, required this.found});
  final double sweep;
  final bool found;

  @override
  void paint(Canvas canvas, Size size) {
    final side = size.shortestSide * 0.66;
    final window = Rect.fromCenter(center: size.center(Offset.zero), width: side, height: side);
    const r = 28.0;
    final rrect = RRect.fromRectAndRadius(window, const Radius.circular(r));

    canvas.drawPath(
      Path.combine(PathOperation.difference, Path()..addRect(Offset.zero & size), Path()..addRRect(rrect)),
      Paint()..color = const Color(0x73000000),
    );

    final corner = Paint()
      ..color = found ? Ember.sealed : Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    const len = 22.0;
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

    if (!found) {
      // 0 → 1 → 0, eased, between 18% and 80% of the window.
      final t = sweep < 0.5 ? sweep * 2 : (1 - sweep) * 2;
      final eased = Curves.easeInOut.transform(t);
      final y = window.top + window.height * (0.18 + 0.62 * eased);
      final line = Rect.fromLTWH(window.left + side * 0.12, y - 1, side * 0.76, 2);
      canvas.drawRect(
        line.inflate(6),
        Paint()
          ..color = const Color(0x55FF4D6D)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
      );
      canvas.drawRect(
        line,
        Paint()..shader = const LinearGradient(colors: [Color(0x00FF8FA3), Color(0xFFFF8FA3), Color(0x00FF8FA3)]).createShader(line),
      );
    }
  }

  @override
  bool shouldRepaint(_Viewfinder old) => old.sweep != sweep || old.found != found;
}

class _Mine extends StatefulWidget {
  const _Mine({super.key});

  @override
  State<_Mine> createState() => _MineState();
}

class _MineState extends State<_Mine> {
  String? _payload;
  String? _nodeId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final payload = await IdentityService.getQrPayload();
    final id = await IdentityService.getMyNodeId();
    if (!mounted) return;
    setState(() {
      _payload = payload;
      _nodeId = id;
    });
  }

  @override
  Widget build(BuildContext context) {
    final payload = _payload;
    if (payload == null) return const Center(child: CircularProgressIndicator());
    return SingleChildScrollView(
      child: Column(
        children: [
          Reveal(
            child: Semantics(
              label: 'Your pairing QR code',
              image: true,
              child: Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  // Always white: scanners read dark-on-light best.
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(30),
                  boxShadow: const [BoxShadow(color: Color(0x59C2233F), blurRadius: 70, offset: Offset(0, 30))],
                ),
                child: QrImageView(
                  data: payload,
                  version: QrVersions.auto,
                  size: 231,
                  padding: EdgeInsets.zero,
                  backgroundColor: Colors.white,
                  eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: Color(0xFF1C1013)),
                  dataModuleStyle: const QrDataModuleStyle(dataModuleShape: QrDataModuleShape.square, color: Color(0xFF1C1013)),
                ),
              ),
            ),
          ),
          const SizedBox(height: 18),
          Text('Your node ID', style: context.type.labelSmall),
          const SizedBox(height: 6),
          Glass(
            radius: 14,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            child: MonoText(_nodeId ?? '', selectable: true, textAlign: TextAlign.center, style: const TextStyle(fontSize: 16, letterSpacing: 1.2)),
          ),
          const SizedBox(height: 18),
          Text(
            'Your guardian opens Add guardian › Scan their QR.',
            textAlign: TextAlign.center,
            style: context.type.bodyMedium?.copyWith(fontSize: 14, color: const Color(0xB3F4ECEE)),
          ),
        ],
      ),
    );
  }
}
