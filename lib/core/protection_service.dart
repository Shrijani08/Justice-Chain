import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'disguise_service.dart';

/// Background protection (step 6b): an Android foreground service with a
/// permanent notification (ProtectionService.kt). It keeps the app's process
/// alive, so the AI keeps listening while the phone is locked or the app is
/// swiped away. In disguise mode the notification looks like a calculator's.
///
/// Android only lets it start while the app is on screen, so [startIfEnabled]
/// is called when monitoring starts. It is on by default; until the redesign's
/// settings screen, the home screen has its on/off row.
class ProtectionService {
  ProtectionService._();

  static const _channel = MethodChannel('in.sakshya/protection');
  static const _enabledKey = 'background_protection';

  static Box get _box => Hive.box('vault_box');

  /// The user's choice; the home screen's switch listens to it.
  static final ValueNotifier<bool> enabled = ValueNotifier<bool>(true);

  /// Reads the saved setting and keeps the notification's wording in step
  /// with disguise mode.
  static Future<void> init() async {
    enabled.value = _box.get(_enabledKey, defaultValue: true) == true;
    DisguiseService.enabled
      ..removeListener(_onDisguiseChanged) // safe to call init again
      ..addListener(_onDisguiseChanged);
  }

  static Future<void> setEnabled(bool on) async {
    await _box.put(_enabledKey, on);
    enabled.value = on;
    if (on) {
      await startIfEnabled();
    } else {
      await stop();
    }
  }

  /// Starts the service if protection is on. Call it while the app is on
  /// screen; a start from the background is refused by Android.
  static Future<bool> startIfEnabled() async {
    if (!enabled.value) return false;
    return _invoke('start', {'disguised': DisguiseService.enabled.value});
  }

  static Future<bool> stop() => _invoke('stop');

  static Future<bool> isRunning() async {
    try {
      return await _channel.invokeMethod<bool>('isRunning') ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  static void _onDisguiseChanged() {
    _invoke('setDisguised', {'disguised': DisguiseService.enabled.value});
  }

  static Future<bool> _invoke(String method, [Map<String, Object?>? arguments]) async {
    try {
      await _channel.invokeMethod<bool>(method, arguments);
      return true;
    } on MissingPluginException {
      // Not Android (or a test): the app works, only while it is open.
      return false;
    } on PlatformException catch (e) {
      developer.log('Background protection $method failed: $e', name: 'JusticeChain.Protection');
      return false;
    }
  }
}
