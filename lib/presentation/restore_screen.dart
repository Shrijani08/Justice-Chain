import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/recovery_service.dart';
import 'home_screen.dart';
import 'design/components.dart';
import 'design/tokens.dart';

/// "Restore with recovery code": brings back a lost phone's identity and
/// lists its recordings from the ledger, so they can be watched again.
class RestoreScreen extends StatefulWidget {
  const RestoreScreen({super.key});

  @override
  State<RestoreScreen> createState() => _RestoreScreenState();
}

class _RestoreScreenState extends State<RestoreScreen> {
  final _formKey = GlobalKey<FormState>();
  final _codeController = TextEditingController();
  final _nameController = TextEditingController();
  final _pinController = TextEditingController();
  final _confirmPinController = TextEditingController();
  bool _working = false;
  String? _codeError;

  @override
  void dispose() {
    for (final c in [_codeController, _nameController, _pinController, _confirmPinController]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _restore() async {
    setState(() => _codeError = null);
    if (!_formKey.currentState!.validate()) return;
    setState(() => _working = true);
    try {
      final found = await RecoveryService.restore(
        code: _codeController.text,
        name: _nameController.text.trim(),
        pin: _pinController.text.trim(),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Identity restored. $found recording${found == 1 ? '' : 's'} found on the ledger. '
            'Pair your guardians again from "Scan QR".'),
      ));
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const MainSafetyScreen()),
        (_) => false,
      );
    } on FormatException catch (e) {
      setState(() => _codeError = e.message);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Restore failed: $e')));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }
  InputDecoration _decoration(String label, {String? error, IconData? icon}) => InputDecoration(
        labelText: label,
        errorText: error,
        counterText: '',
        prefixIcon: icon == null ? null : Icon(icon),
      );

  static final _digitsOnly = [FilteringTextInputFormatter.digitsOnly];

  @override
  Widget build(BuildContext context) {
    final c = context.sak;
    final pinStyle = context.type.bodyLarge?.copyWith(letterSpacing: 4);
    return SakPage(
      title: 'Restore',
      slivers: [
        SliverToBoxAdapter(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Form(
                key: _formKey,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: SakSpace.gutter),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Enter the code you wrote down when you first set up the app. '
                        'This phone becomes your old phone: same identity, and your recordings come back from the ledger.',
                        style: context.type.bodyMedium?.copyWith(color: c.inkSecondary),
                      ),
                      const SizedBox(height: SakSpace.xl),
                      TextFormField(
                        controller: _codeController,
                        key: const ValueKey('restore-code'),
                        textCapitalization: TextCapitalization.characters,
                        minLines: 2,
                        maxLines: 2,
                        style: context.type.bodyLarge?.copyWith(
                          fontFamily: SakMono.family,
                          fontFamilyFallback: SakMono.fallback,
                          letterSpacing: 1.5,
                        ),
                        decoration: _decoration('Recovery code', error: _codeError),
                        validator: (v) => v == null || v.trim().isEmpty ? 'Enter your recovery code' : null,
                      ),
                      const SizedBox(height: SakSpace.xl),
                      Padding(
                        padding: const EdgeInsets.only(left: SakSpace.xs, bottom: SakSpace.sm),
                        child: Text('This phone', style: context.type.labelMedium),
                      ),
                      TextFormField(
                        controller: _nameController,
                        key: const ValueKey('restore-name'),
                        textInputAction: TextInputAction.next,
                        textCapitalization: TextCapitalization.words,
                        decoration: _decoration('Your name', icon: Icons.person_outline_rounded),
                        validator: (v) => v == null || v.trim().isEmpty ? 'Name is required' : null,
                      ),
                      const SizedBox(height: SakSpace.md),
                      TextFormField(
                        controller: _pinController,
                        key: const ValueKey('restore-pin'),
                        keyboardType: TextInputType.number,
                        inputFormatters: _digitsOnly,
                        textInputAction: TextInputAction.next,
                        obscureText: true,
                        maxLength: 6,
                        style: pinStyle,
                        decoration: _decoration('New vault PIN (4-6 digits)', icon: Icons.lock_outline_rounded),
                        validator: (v) => v == null || !RegExp(r'^\d{4,6}$').hasMatch(v) ? 'PIN must be 4-6 digits' : null,
                      ),
                      const SizedBox(height: SakSpace.md),
                      TextFormField(
                        controller: _confirmPinController,
                        key: const ValueKey('restore-confirm-pin'),
                        keyboardType: TextInputType.number,
                        inputFormatters: _digitsOnly,
                        textInputAction: TextInputAction.done,
                        obscureText: true,
                        maxLength: 6,
                        style: pinStyle,
                        decoration: _decoration('Confirm PIN', icon: Icons.lock_reset_rounded),
                        validator: (v) => v != _pinController.text ? 'PINs do not match' : null,
                      ),
                      const SizedBox(height: SakSpace.xl),
                      SakButton(
                        key: const ValueKey('restore-button'),
                        label: 'Restore',
                        icon: Icons.restore_rounded,
                        loading: _working,
                        onPressed: _working ? null : _restore,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
