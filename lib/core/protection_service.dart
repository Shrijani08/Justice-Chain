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
/// A clip from [ProtectionService.recordInBackground]: an MP4 either way.
class BackgroundClip {
  const BackgroundClip({required this.path, required this.audioOnly});

  final String path;

  /// The camera couldn't be used, so only sound was recorded.
  final bool audioOnly;
}

class ProtectionService {
  ProtectionService._();

  static const _channel = MethodChannel('in.sakshya/protection');
  static const _enabledKey = 'background_protection';
  static const _listenWhileDisguisedKey = 'listen_while_disguised';

  static Box get _box => Hive.box('vault_box');

  /// The user's choice; the home screen's switch listens to it.
  static final ValueNotifier<bool> enabled = ValueNotifier<bool>(true);

  /// "Keep listening while disguised" (decided 15-10-2026, on by default).
  /// Off: nothing listens under the calculator, so Android shows no
  /// microphone dot; only "112 =" or the SOS button records. The
  /// EmergencyController applies it.
  static final ValueNotifier<bool> listenWhileDisguised = ValueNotifier<bool>(true);

  /// Reads the saved setting and keeps the notification's wording in step
  /// with disguise mode.
  static Future<void> init() async {
    enabled.value = _box.get(_enabledKey, defaultValue: true) == true;
    listenWhileDisguised.value = _box.get(_listenWhileDisguisedKey, defaultValue: true) == true;
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

  static Future<void> setListenWhileDisguised(bool on) async {
    await _box.put(_listenWhileDisguisedKey, on);
    listenWhileDisguised.value = on;
  }

  /// Whether the disguised notification would still show. Android heads
  /// every notification with the app's real name, so the user turns its
  /// channel off once ([openDisguisedNotificationSettings]).
  static Future<bool> disguisedNotificationVisible() async {
    try {
      return await _channel.invokeMethod<bool>('disguisedNotificationVisible') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Opens Android's settings page for the disguised notification's channel.
  static Future<bool> openDisguisedNotificationSettings() => _invoke('openDisguisedNotificationSettings');

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

  /// Records a clip natively while the app isn't on screen (BackgroundRecorder.kt):
  /// video, or audio only if the camera can't be used. Completes when the
  /// clip is finished, after at most [maxLength] or [stopRecording]; null if
  /// nothing could be recorded.
  static Future<BackgroundClip?> recordInBackground(Duration maxLength) async {
    try {
      final result = await _channel.invokeMapMethod<String, Object?>(
        'record',
        {'seconds': maxLength.inSeconds},
      );
      final path = result?['path'];
      if (path is! String) {
        developer.log('Background recording failed: ${result?['error']}', name: 'JusticeChain.Protection');
        return null;
      }
      return BackgroundClip(path: path, audioOnly: result?['kind'] == 'audio');
    } on MissingPluginException {
      return null;
    } on PlatformException catch (e) {
      developer.log('Background recording failed: $e', name: 'JusticeChain.Protection');
      return null;
    }
  }

  /// Ends a [recordInBackground] clip early.
  static Future<bool> stopRecording() => _invoke('stopRecording');

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
