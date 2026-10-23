import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../core/identity_service.dart';
import 'design/components.dart';
import 'design/tokens.dart';

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
    if (!mounted) return;
    setState(() {
      _qrPayload = payload;
      _nodeId = id;
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.sak;
    final payload = _qrPayload;
    return SakPage(
      title: 'Add Guardian',
      slivers: [
        // A plain box, not SliverFillRemaining: that measures its child's
        // intrinsic height, which QrImageView (a LayoutBuilder) can't give.
        SliverToBoxAdapter(
          child: payload == null
              ? const Padding(
                  padding: EdgeInsets.only(top: SakSpace.xxl),
                  child: Center(child: CircularProgressIndicator()),
                )
              : Padding(
                  padding: const EdgeInsets.symmetric(horizontal: SakSpace.gutter),
                  child: Column(
                    children: [
                      Text(
                        'Have a trusted guardian scan this code with Scan QR on their phone.',
                        textAlign: TextAlign.center,
                        style: context.type.bodyMedium?.copyWith(color: c.inkSecondary),
                      ),
                      const SizedBox(height: SakSpace.xl),
                      Reveal(
                        child: Semantics(
                          label: 'Pairing QR code',
                          image: true,
                          child: Container(
                            padding: const EdgeInsets.all(SakSpace.lg),
                            decoration: BoxDecoration(
                              // Always white: scanners read dark-on-light best.
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(SakRadius.sheet),
                              boxShadow: [
                                BoxShadow(
                                  color: c.accent.withValues(alpha: 0.14),
                                  blurRadius: 32,
                                  offset: const Offset(0, 12),
                                ),
                              ],
                            ),
                            child: QrImageView(
                              data: payload,
                              version: QrVersions.auto,
                              size: 240.0,
                              backgroundColor: Colors.white,
                              eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: Color(0xFF1C1013)),
                              dataModuleStyle: const QrDataModuleStyle(
                                dataModuleShape: QrDataModuleShape.square,
                                color: Color(0xFF1C1013),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: SakSpace.xl),
                      Reveal(
                        index: 1,
                        child: Column(
                          children: [
                            Text('Your Secure Node ID', style: context.type.labelMedium),
                            const SizedBox(height: SakSpace.sm),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: SakSpace.lg, vertical: SakSpace.md),
                              decoration: BoxDecoration(
                                color: c.surface,
                                borderRadius: BorderRadius.circular(SakRadius.control),
                                border: Border.all(color: c.separator),
                              ),
                              child: MonoText(
                                _nodeId ?? '',
                                selectable: true,
                                textAlign: TextAlign.center,
                                style: context.type.titleLarge?.copyWith(letterSpacing: 2),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }
}
