import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:justice_chain/core/shamir.dart';

Uint8List _randomBytes(Random rng, int length) =>
    Uint8List.fromList(List<int>.generate(length, (_) => rng.nextInt(256)));

List<Uint8List> _randomCoefficients(Random rng, int threshold, int length) =>
    List<Uint8List>.generate(threshold - 1, (_) => _randomBytes(rng, length));

void main() {
  group('Shamir 2-of-3 (guardian quorum)', () {
    final rng = Random(42);
    final secret = _randomBytes(rng, 32); // AES-256 incident key size
    final coefficients = _randomCoefficients(rng, 2, 32);
    final shares = [
      for (var x = 1; x <= 3; x++)
        Shamir.shareAt(secret: secret, coefficients: coefficients, x: x),
    ];

    test('every pair of shares reconstructs the secret', () {
      for (var i = 0; i < 3; i++) {
        for (var j = 0; j < 3; j++) {
          if (i == j) continue;
          expect(Shamir.combine([shares[i], shares[j]]), secret,
              reason: 'shares ${shares[i].x} and ${shares[j].x}');
        }
      }
    });

    test('all three shares also reconstruct the secret', () {
      expect(Shamir.combine(shares), secret);
    });

    test('a single share does not reveal the secret', () {
      for (final share in shares) {
        expect(Shamir.combine([share]), isNot(equals(secret)));
        expect(share.y, isNot(equals(secret)));
      }
    });

    test('a share issued later with the same coefficients combines with earlier ones', () {
      // Mirrors issuing a share to a guardian paired after the recording.
      final lateShare =
          Shamir.shareAt(secret: secret, coefficients: coefficients, x: 7);
      expect(Shamir.combine([shares[0], lateShare]), secret);
      expect(Shamir.combine([lateShare, shares[2]]), secret);
    });

    test('shares are deterministic for the same inputs', () {
      final again =
          Shamir.shareAt(secret: secret, coefficients: coefficients, x: 2);
      expect(again.y, shares[1].y);
    });

    test('a corrupted share reconstructs the wrong secret', () {
      final tampered = (x: shares[1].x, y: Uint8List.fromList(shares[1].y));
      tampered.y[0] ^= 0x01;
      expect(Shamir.combine([shares[0], tampered]), isNot(equals(secret)));
    });
  });

  test('matches a hand-computed GF(256) value', () {
    // f(x) = 0x53 + 0xCA*x. f(1) = 0xCA ^ 0x53 = 0x99.
    // f(2) = xtime(0xCA) ^ 0x53 = 0x8F ^ 0x53 = 0xDC.
    final secret = Uint8List.fromList([0x53]);
    final coefficients = [Uint8List.fromList([0xCA])];
    expect(Shamir.shareAt(secret: secret, coefficients: coefficients, x: 1).y,
        [0x99]);
    expect(Shamir.shareAt(secret: secret, coefficients: coefficients, x: 2).y,
        [0xDC]);
  });

  test('3-of-5 threshold: any 3 shares work, 2 do not', () {
    final rng = Random(7);
    final secret = _randomBytes(rng, 32);
    final coefficients = _randomCoefficients(rng, 3, 32);
    final shares = [
      for (var x = 1; x <= 5; x++)
        Shamir.shareAt(secret: secret, coefficients: coefficients, x: x),
    ];

    for (var a = 0; a < 5; a++) {
      for (var b = a + 1; b < 5; b++) {
        expect(Shamir.combine([shares[a], shares[b]]), isNot(equals(secret)));
        for (var c = b + 1; c < 5; c++) {
          expect(Shamir.combine([shares[a], shares[b], shares[c]]), secret);
        }
      }
    }
  });

  test('round-trips random secrets across all share indices', () {
    final rng = Random(1234);
    for (var round = 0; round < 50; round++) {
      final secret = _randomBytes(rng, 1 + rng.nextInt(64));
      final coefficients = _randomCoefficients(rng, 2, secret.length);
      final x1 = 1 + rng.nextInt(255);
      var x2 = 1 + rng.nextInt(255);
      while (x2 == x1) {
        x2 = 1 + rng.nextInt(255);
      }
      final s1 = Shamir.shareAt(secret: secret, coefficients: coefficients, x: x1);
      final s2 = Shamir.shareAt(secret: secret, coefficients: coefficients, x: x2);
      expect(Shamir.combine([s1, s2]), secret, reason: 'round $round, x=$x1,$x2');
    }
  });

  group('input validation', () {
    final secret = Uint8List.fromList([1, 2, 3]);
    final coefficients = [Uint8List.fromList([4, 5, 6])];

    test('rejects share index outside 1..255', () {
      expect(
        () => Shamir.shareAt(secret: secret, coefficients: coefficients, x: 0),
        throwsArgumentError,
      );
      expect(
        () => Shamir.shareAt(secret: secret, coefficients: coefficients, x: 256),
        throwsArgumentError,
      );
    });

    test('rejects coefficients of the wrong length', () {
      expect(
        () => Shamir.shareAt(
          secret: secret,
          coefficients: [Uint8List.fromList([1, 2])],
          x: 1,
        ),
        throwsArgumentError,
      );
    });

    test('combine rejects no shares, duplicate indices and mismatched lengths', () {
      final s1 = Shamir.shareAt(secret: secret, coefficients: coefficients, x: 1);
      final s2 = Shamir.shareAt(secret: secret, coefficients: coefficients, x: 2);

      expect(() => Shamir.combine([]), throwsArgumentError);
      expect(() => Shamir.combine([s1, s1]), throwsArgumentError);
      expect(
        () => Shamir.combine([s1, (x: s2.x, y: Uint8List.fromList([1, 2]))]),
        throwsArgumentError,
      );
    });
  });
}
