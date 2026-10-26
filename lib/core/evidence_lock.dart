import 'package:flutter/foundation.dart' show visibleForTesting;

import 'identity_service.dart';

/// Keeps recordings behind the vault PIN, so someone holding the unlocked
/// phone can't open them (judge review finding S5). One correct PIN opens
/// the evidence screens for [unlockFor]; leaving the app locks them again.
/// Recording never asks for the PIN: SOS works while locked.
class EvidenceLock {
  EvidenceLock._();

  static const unlockFor = Duration(minutes: 5);

  /// Wrong PINs allowed before [lockout] starts.
  static const maxTries = 5;
  static const lockout = Duration(seconds: 30);

  static DateTime? _unlockedUntil;
  static int _wrongTries = 0;
  static DateTime? _blockedUntil;

  @visibleForTesting
  static DateTime Function() now = DateTime.now;

  @visibleForTesting
  static void resetForTest() {
    _unlockedUntil = null;
    _wrongTries = 0;
    _blockedUntil = null;
    now = DateTime.now;
  }

  static bool get isUnlocked => _unlockedUntil != null && now().isBefore(_unlockedUntil!);

  /// How long until another PIN may be tried; zero when one may be now.
  static Duration get waitBeforeNextTry {
    final until = _blockedUntil;
    if (until == null) return Duration.zero;
    final left = until.difference(now());
    return left.isNegative ? Duration.zero : left;
  }

  /// Phones registered without a PIN have nothing to lock with.
  static Future<bool> hasPin() => IdentityService.hasPin();

  /// Unlocks for [unlockFor] if [pin] is the vault PIN. After [maxTries]
  /// wrong ones, refuses every try for [lockout].
  static Future<bool> unlock(String pin) async {
    if (waitBeforeNextTry > Duration.zero) return false;
    if (await IdentityService.verifyPin(pin)) {
      _wrongTries = 0;
      _blockedUntil = null;
      _unlockedUntil = now().add(unlockFor);
      return true;
    }
    if (++_wrongTries >= maxTries) {
      _wrongTries = 0;
      _blockedUntil = now().add(lockout);
    }
    return false;
  }

  static void lock() => _unlockedUntil = null;
}
