import 'dart:typed_data';

typedef ShamirShare = ({int x, Uint8List y});

/// Shamir secret sharing over GF(2^8) (AES polynomial 0x11b), applied
/// independently to each byte of the secret. Any [threshold] shares
/// reconstruct the secret; fewer reveal nothing about it.
class Shamir {
  Shamir._();

  static final Uint8List _exp = Uint8List(510);
  static final Uint8List _log = Uint8List(256);
  static bool _tablesReady = false;

  static void _ensureTables() {
    if (_tablesReady) return;
    var x = 1;
    for (var i = 0; i < 255; i++) {
      _exp[i] = x;
      _exp[i + 255] = x;
      _log[x] = i;
      // Multiply by the generator 0x03: x ^ xtime(x).
      final xtime = ((x << 1) ^ ((x & 0x80) != 0 ? 0x1b : 0)) & 0xff;
      x ^= xtime;
    }
    _tablesReady = true;
  }

  static int _mul(int a, int b) {
    if (a == 0 || b == 0) return 0;
    return _exp[_log[a] + _log[b]];
  }

  static int _div(int a, int b) {
    if (b == 0) throw ArgumentError('Division by zero in GF(256).');
    if (a == 0) return 0;
    return _exp[(_log[a] - _log[b] + 255) % 255];
  }

  /// Evaluates the sharing polynomial at [x]. [coefficients] are the
  /// non-constant terms (threshold - 1 of them), each as long as [secret].
  /// Passing the same coefficients later yields shares consistent with
  /// earlier ones, which is what lets new guardians be issued shares
  /// after the fact.
  static ShamirShare shareAt({
    required Uint8List secret,
    required List<Uint8List> coefficients,
    required int x,
  }) {
    _ensureTables();
    if (x < 1 || x > 255) {
      throw ArgumentError('Share index must be in 1..255, got $x.');
    }
    for (final c in coefficients) {
      if (c.length != secret.length) {
        throw ArgumentError('Coefficient length must match secret length.');
      }
    }

    final y = Uint8List(secret.length);
    for (var b = 0; b < secret.length; b++) {
      var acc = 0;
      for (var i = coefficients.length - 1; i >= 0; i--) {
        acc = _mul(acc, x) ^ coefficients[i][b];
      }
      y[b] = _mul(acc, x) ^ secret[b];
    }
    return (x: x, y: y);
  }

  /// Reconstructs the secret from [shares] via Lagrange interpolation at 0.
  /// The caller must supply at least the threshold number of shares;
  /// fewer silently produce a wrong value (detected downstream by AES-GCM).
  static Uint8List combine(List<ShamirShare> shares) {
    _ensureTables();
    if (shares.isEmpty) throw ArgumentError('No shares to combine.');

    final length = shares.first.y.length;
    final xs = <int>{};
    for (final s in shares) {
      if (s.y.length != length) {
        throw ArgumentError('Shares have mismatched lengths.');
      }
      if (!xs.add(s.x)) throw ArgumentError('Duplicate share index ${s.x}.');
    }

    final secret = Uint8List(length);
    for (var i = 0; i < shares.length; i++) {
      var basis = 1;
      for (var j = 0; j < shares.length; j++) {
        if (i == j) continue;
        basis = _mul(basis, _div(shares[j].x, shares[j].x ^ shares[i].x));
      }
      for (var b = 0; b < length; b++) {
        secret[b] ^= _mul(shares[i].y[b], basis);
      }
    }
    return secret;
  }
}
