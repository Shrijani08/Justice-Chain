import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/identity_service.dart';
// Note: We updated this import to match the actual functional UI screen.
import 'home_screen.dart';
import 'recovery_code_screen.dart';
import 'restore_screen.dart';
import 'design/components.dart';
import 'design/tokens.dart';

class RegistrationScreen extends StatefulWidget {
  const RegistrationScreen({super.key});

  @override
  State<RegistrationScreen> createState() => _RegistrationScreenState();
}

class _RegistrationScreenState extends State<RegistrationScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _pinController = TextEditingController();
  final _confirmPinController = TextEditingController();

  bool _isProcessing = false;

  @override
  void dispose() {
    _nameController.dispose();
    _pinController.dispose();
    _confirmPinController.dispose();
    super.dispose();
  }

  Future<void> _processRegistration() async {
    if (_formKey.currentState!.validate()) {
      setState(() => _isProcessing = true);

      try {
        await IdentityService.registerNode(
          name: _nameController.text.trim(),
          pin: _pinController.text.trim(),
        );

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Your identity is ready.')),
          );

          // Show the recovery code once, then the application dashboard.
          // The navigator outlives this screen, which is replaced first.
          final navigator = Navigator.of(context);
          navigator.pushReplacement(
            MaterialPageRoute(
              builder: (context) => RecoveryCodeScreen(
                onDone: () => navigator.pushReplacement(
                  MaterialPageRoute(builder: (context) => const MainSafetyScreen()),
                ),
              ),
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not create your identity: $e')),
          );
        }
      } finally {
        if (mounted) {
          setState(() => _isProcessing = false);
        }
      }
    }
  }

  static final _digitsOnly = [FilteringTextInputFormatter.digitsOnly];

  @override
  Widget build(BuildContext context) {
    final c = context.sak;
    return Scaffold(
      backgroundColor: c.background,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(SakSpace.xl),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Form(
                key: _formKey,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Reveal(
                      child: Column(
                        children: [
                          const SealMark(),
                          const SizedBox(height: SakSpace.xl),
                          Text(
                            'Create Your Identity',
                            textAlign: TextAlign.center,
                            style: context.type.headlineMedium,
                          ),
                          const SizedBox(height: SakSpace.sm),
                          Text(
                            'Your keys are made on this phone and kept in its hardware keystore.',
                            textAlign: TextAlign.center,
                            style: context.type.bodyMedium?.copyWith(color: c.inkSecondary),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: SakSpace.xxl),
                    Reveal(
                      index: 1,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          TextFormField(
                            controller: _nameController,
                            textInputAction: TextInputAction.next,
                            textCapitalization: TextCapitalization.words,
                            decoration: const InputDecoration(
                              labelText: 'Your name',
                              prefixIcon: Icon(Icons.person_outline_rounded),
                            ),
                            validator: (value) => value == null || value.trim().isEmpty
                                ? 'Enter your name'
                                : null,
                          ),
                          const SizedBox(height: SakSpace.md),
                          TextFormField(
                            controller: _pinController,
                            keyboardType: TextInputType.number,
                            inputFormatters: _digitsOnly,
                            textInputAction: TextInputAction.next,
                            obscureText: true,
                            maxLength: 6,
                            style: context.type.bodyLarge?.copyWith(letterSpacing: 4.0),
                            decoration: const InputDecoration(
                              labelText: 'Vault PIN (4-6 digits)',
                              prefixIcon: Icon(Icons.lock_outline_rounded),
                              counterText: '',
                            ),
                            validator: (value) {
                              if (value == null || value.length < 4) {
                                return 'PIN must be at least 4 digits';
                              }
                              return null;
                            },
                          ),
                          const SizedBox(height: SakSpace.md),
                          TextFormField(
                            controller: _confirmPinController,
                            keyboardType: TextInputType.number,
                            inputFormatters: _digitsOnly,
                            textInputAction: TextInputAction.done,
                            obscureText: true,
                            maxLength: 6,
                            style: context.type.bodyLarge?.copyWith(letterSpacing: 4.0),
                            decoration: const InputDecoration(
                              labelText: 'Confirm PIN',
                              prefixIcon: Icon(Icons.lock_reset_rounded),
                              counterText: '',
                            ),
                            onFieldSubmitted: (_) {
                              if (!_isProcessing) _processRegistration();
                            },
                            validator: (value) {
                              if (value != _pinController.text) {
                                return 'PINs do not match';
                              }
                              return null;
                            },
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: SakSpace.xl),
                    Reveal(
                      index: 2,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SakButton(
                            label: 'Generate Secure Keys',
                            icon: Icons.key_rounded,
                            loading: _isProcessing,
                            onPressed: _isProcessing ? null : _processRegistration,
                          ),
                          const SizedBox(height: SakSpace.sm),
                          TextButton(
                            onPressed: _isProcessing
                                ? null
                                : () => Navigator.push(
                                      context,
                                      MaterialPageRoute(builder: (context) => const RestoreScreen()),
                                    ),
                            child: const Text(
                              'Lost your phone? Restore with recovery code',
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
