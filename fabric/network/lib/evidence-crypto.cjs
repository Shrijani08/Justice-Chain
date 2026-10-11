'use strict';

/**
 * The app's key-piece formats in Node, for the authority side: unsealing a
 * piece sealed with EvidenceEncryptor.sealShare and recombining pieces as
 * lib/core/shamir.dart does. Used by the Step 9 check and the officer
 * portal (Step 10); any change must keep both matching the Dart code.
 */

const crypto = require('crypto');

// DER prefix that turns a raw 32-byte X25519 key into an SPKI key.
const X25519_SPKI_PREFIX = Buffer.from('302a300506032b656e032100', 'hex');
const GUARDIAN_WRAP_INFO = 'justice-chain-guardian-wrap-v1';

/**
 * Decrypts an app box: nonce(12) + mac(16) + AES-256-GCM ciphertext, as
 * EvidenceEncryptor writes .enc clips and sealed pieces. Throws if [key]
 * is wrong or a byte was changed.
 */
function openBox(box, key) {
  if (box.length < 28) throw new Error('Box too short to contain nonce and MAC.');
  const decipher = crypto.createDecipheriv('aes-256-gcm', key, box.subarray(0, 12));
  decipher.setAuthTag(box.subarray(12, 28));
  return Buffer.concat([decipher.update(box.subarray(28)), decipher.final()]);
}

/**
 * Opens a piece sealed to [privateKey] (an X25519 KeyObject, e.g. the
 * evidence desk key) by the holder of [senderPublicKeyB64]: X25519, then
 * HKDF-SHA256 with no salt, then AES-256-GCM over nonce(12) + mac(16) +
 * ciphertext of [x] ++ y. Returns {x, y}.
 */
function unsealShare(sealedShareB64, privateKey, senderPublicKeyB64) {
  const sender = crypto.createPublicKey({
    key: Buffer.concat([X25519_SPKI_PREFIX, Buffer.from(senderPublicKeyB64, 'base64')]),
    format: 'der',
    type: 'spki',
  });
  const shared = crypto.diffieHellman({ privateKey, publicKey: sender });
  const key = Buffer.from(crypto.hkdfSync('sha256', shared, Buffer.alloc(0), GUARDIAN_WRAP_INFO, 32));
  const plain = openBox(Buffer.from(sealedShareB64, 'base64'), key);
  return { x: plain[0], y: plain.subarray(1) };
}

// GF(2^8) with the AES polynomial 0x11b and generator 0x03, as in shamir.dart.
const EXP = new Uint8Array(510);
const LOG = new Uint8Array(256);
{
  let value = 1;
  for (let i = 0; i < 255; i++) {
    EXP[i] = value;
    EXP[i + 255] = value;
    LOG[value] = i;
    value ^= ((value << 1) ^ (value & 0x80 ? 0x1b : 0)) & 0xff;
  }
}

function mul(a, b) {
  return a === 0 || b === 0 ? 0 : EXP[LOG[a] + LOG[b]];
}

function div(a, b) {
  if (b === 0) throw new Error('Division by zero in GF(256).');
  return a === 0 ? 0 : EXP[(LOG[a] - LOG[b] + 255) % 255];
}

/**
 * Rebuilds the secret from pieces [{x, y}] by Lagrange interpolation at 0.
 * Fewer than the threshold silently gives a wrong key, which AES-GCM then
 * rejects when decrypting the clip.
 */
function combineShares(shares) {
  if (shares.length === 0) throw new Error('No shares to combine.');
  const length = shares[0].y.length;
  const xs = new Set(shares.map((s) => s.x));
  if (xs.size !== shares.length) throw new Error('Duplicate share index.');
  const secret = Buffer.alloc(length);
  shares.forEach((si, i) => {
    let basis = 1;
    shares.forEach((sj, j) => {
      if (i !== j) basis = mul(basis, div(sj.x, sj.x ^ si.x));
    });
    for (let b = 0; b < length; b++) secret[b] ^= mul(si.y[b], basis);
  });
  return secret;
}

module.exports = { openBox, unsealShare, combineShares };
