import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'identity_service.dart';

/// Which launcher entry the phone shows for the app (AndroidManifest.xml).
enum LauncherFace { sakshya, calculator }

/// Disguise mode: the app appears on the phone as "Calculator", opens on a
/// working calculator, and needs the vault PIN ("PIN then =") to show
/// Sakshya. "112 then =" starts an SOS recording without unlocking.
///
/// Android 10+ can't hide an app, so it looks ordinary instead. The real
/// name still shows in Settings → Apps.
class DisguiseService {
  DisguiseService._();

  static const _channel = MethodChannel('in.sakshya/disguise');
  static const _enabledKey = 'disguise_mode';

  static Box get _box => Hive.box('vault_box');

  /// Whether disguise mode is on. Listened to for the app's task name.
  static final ValueNotifier<bool> enabled = ValueNotifier<bool>(false);

  /// Reads the saved setting and makes the launcher match it (repairs a
  /// switch that was interrupted, e.g. by the app being killed).
  static Future<void> init() async {
    enabled.value = _box.get(_enabledKey) == true;
    await _showFace(enabled.value ? LauncherFace.calculator : LauncherFace.sakshya);
  }

  /// Turns disguise mode on or off. It needs the vault PIN to get back in,
  /// so it can only be turned on after registration.
  static Future<void> setEnabled(bool on) async {
    if (on && !await IdentityService.isRegistered()) {
      throw StateError('Disguise mode needs the vault PIN set at registration');
    }
    await _box.put(_enabledKey, on);
    enabled.value = on;
    await _showFace(on ? LauncherFace.calculator : LauncherFace.sakshya);
  }

  /// The PIN typed into the calculator; true opens Sakshya.
  static Future<bool> unlock(String pin) => IdentityService.verifyPin(pin);

  /// The launcher entry the phone shows now, or null where there is no
  /// launcher to switch (not Android).
  static Future<LauncherFace?> launcherFace() async {
    try {
      final face = await _channel.invokeMethod<String>('getLauncherFace');
      return LauncherFace.values.asNameMap()[face];
    } on MissingPluginException {
      return null;
    }
  }

  static Future<void> _showFace(LauncherFace face) async {
    try {
      if (await launcherFace() == face) return;
      await _channel.invokeMethod<String>('setLauncherFace', {'face': face.name});
      developer.log('Launcher face switched to ${face.name}.', name: 'JusticeChain.Disguise');
    } on MissingPluginException {
      // No launcher faces on this platform; the in-app calculator still works.
    } on PlatformException catch (e) {
      // The in-app calculator still works; the next start tries again.
      developer.log('Launcher face switch failed: $e', name: 'JusticeChain.Disguise');
    }
  }
}
