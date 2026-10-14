import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';

/// Everything a phone's identity is made from, derived from its recovery
/// secret. The same code on a new phone gives back exactly these keys.
typedef RecoveryKeys = ({
  List<int> ed25519Seed,
  List<int> x25519Seed,
  BigInt anchoringKey,
  List<int> evidenceRoot,
});

/// The victim's recovery code (decision doc 08-10-2026, option 1): 128
/// random bits shown once at registration as six groups of five characters
/// (Crockford base32, e.g. `K7Q2M-9XMPA-…`). It carries a 22-bit checksum, so
/// a mistyped code is refused instead of restoring a stranger's identity.
class RecoveryCode {
  RecoveryCode._();

  static const secretLength = 16;
  static const _alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  static const _checksumBits = 22;
  static const _length = 30; // (128 + 22) / 5
  static final _secp256k1Order =
      BigInt.parse('fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141', radix: 16);

  static List<int> newSecret() {
    final random = Random.secure();
    return List<int>.generate(secretLength, (_) => random.nextInt(256));
  }

  /// The code as shown to the user: `XXXXX-XXXXX-XXXXX-XXXXX-XXXXX-XXXXX`.
  static String format(List<int> secret) {
    if (secret.length != secretLength) throw ArgumentError('A recovery secret is $secretLength bytes');
    var value = (_toBigInt(secret) << _checksumBits) | _checksum(secret);
    final chars = List.filled(_length, '');
    for (var i = _length - 1; i >= 0; i--) {
      chars[i] = _alphabet[(value & BigInt.from(31)).toInt()];
      value >>= 5;
    }
    return [for (var i = 0; i < _length; i += 5) chars.sublist(i, i + 5).join()].join('-');
  }

  /// Reads a typed code back into its secret. Case, spaces and dashes don't
  /// matter, and O/I/L are read as 0/1/1. Throws [FormatException] for a
  /// code of the wrong length or with a typo.
  static Uint8List parse(String code) {
    final cleaned = code
        .toUpperCase()
        .replaceAll(RegExp(r'[\s-]'), '')
        .replaceAll('O', '0')
        .replaceAll(RegExp('[IL]'), '1');
    if (cleaned.length != _length) {
      throw const FormatException('A recovery code has 30 letters and digits');
    }
    var value = BigInt.zero;
    for (final ch in cleaned.split('')) {
      final digit = _alphabet.indexOf(ch);
      if (digit < 0) throw FormatException('"$ch" is not used in recovery codes');
      value = (value << 5) | BigInt.from(digit);
    }
    final checksum = value & ((BigInt.one << _checksumBits) - BigInt.one);
    final secret = _fromBigInt(value >> _checksumBits, secretLength);
    if (checksum != _checksum(secret)) {
      throw const FormatException('This recovery code has a typo; check each group');
    }
    return secret;
  }

  /// The phone's keys, each from its own HKDF label so none reveals another.
  static Future<RecoveryKeys> deriveKeys(List<int> secret) async {
    Future<List<int>> derive(String label) async {
      final key = await Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
        secretKey: SecretKey(secret),
        nonce: utf8.encode('sakshya-recovery-v1'),
        info: utf8.encode(label),
      );
      return key.extractBytes();
    }

    // A secp256k1 key must be in 1..n-1; retry with a counter in the
    // (about 1 in 2^128) case it isn't.
    var anchoring = BigInt.zero;
    for (var i = 0; anchoring == BigInt.zero || anchoring >= _secp256k1Order; i++) {
      anchoring = _toBigInt(await derive('secp256k1-anchoring/$i'));
    }
    return (
      ed25519Seed: await derive('ed25519-identity'),
      x25519Seed: await derive('x25519-encryption'),
      anchoringKey: anchoring,
      evidenceRoot: await derive('evidence-root'),
    );
  }

  /// One clip's AES-256 key, from the evidence root and the clip's content
  /// hash (which the ledger records), so a restored phone can rebuild it.
  static Future<SecretKey> clipKey(List<int> evidenceRoot, String plaintextHashHex) =>
      Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
        secretKey: SecretKey(evidenceRoot),
        nonce: utf8.encode('sakshya-clip-key-v1'),
        info: utf8.encode(plaintextHashHex.toLowerCase()),
      );

  static BigInt _checksum(List<int> secret) =>
      _toBigInt(crypto.sha256.convert(secret).bytes.sublist(0, 3)) >> (24 - _checksumBits);

  static BigInt _toBigInt(List<int> bytes) =>
      bytes.fold(BigInt.zero, (value, b) => (value << 8) | BigInt.from(b));

  static Uint8List _fromBigInt(BigInt value, int length) {
    final out = Uint8List(length);
    for (var i = length - 1; i >= 0; i--) {
      out[i] = (value & BigInt.from(255)).toInt();
      value >>= 8;
    }
    return out;
  }
}
