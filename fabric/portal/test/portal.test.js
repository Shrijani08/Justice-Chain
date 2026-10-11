'use strict';

// The portal's unseal, Shamir and decryption code against sample outputs
// made by the app itself (test/portal_vectors_test.dart). Run: npm test

const { test } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('crypto');
const vectors = require('./app_vectors.json');
const { openBox, unsealShare, combineShares } = require('../../network/lib/evidence-crypto.cjs');

// DER prefix that turns a raw 32-byte X25519 seed into a PKCS#8 private key.
const X25519_PKCS8_PREFIX = Buffer.from('302e020100300506032b656e04220420', 'hex');
const desk = crypto.createPrivateKey({
  key: Buffer.concat([X25519_PKCS8_PREFIX, Buffer.from(vectors.deskPrivateSeed, 'base64')]),
  format: 'der',
  type: 'pkcs8',
});
const ciphertext = Buffer.from(vectors.ciphertext, 'base64');
const plaintext = Buffer.from(vectors.plaintext, 'base64');

const unsealed = vectors.pieces.map((p) => unsealShare(p.sealedShare, desk, vectors.victimX25519Public));

test('the desk key unseals every piece the app sealed, with the right index', () => {
  assert.deepEqual(unsealed.map((s) => s.x), [1, 2, 3, 4]);
  for (const share of unsealed) assert.equal(share.y.length, 32);
});

test('any two pieces, including the late one, rebuild the key and open the clip', () => {
  for (let i = 0; i < unsealed.length; i++) {
    for (let j = i + 1; j < unsealed.length; j++) {
      const key = combineShares([unsealed[i], unsealed[j]]);
      const opened = openBox(ciphertext, key);
      assert.deepEqual(opened, plaintext, `pieces ${unsealed[i].x} and ${unsealed[j].x}`);
      assert.equal(crypto.createHash('sha256').update(opened).digest('hex'), vectors.plaintextHash);
    }
  }
});

test('one piece alone, or a changed byte, does not open the clip', () => {
  assert.throws(() => openBox(ciphertext, combineShares([unsealed[0]])));
  const tampered = Buffer.from(ciphertext);
  tampered[tampered.length - 1] ^= 1;
  assert.throws(() => openBox(tampered, combineShares(unsealed.slice(0, 2))));
});

test('a piece sealed to the desk does not open with another key', () => {
  const other = crypto.generateKeyPairSync('x25519').privateKey;
  assert.throws(() => unsealShare(vectors.pieces[0].sealedShare, other, vectors.victimX25519Public));
});

test('duplicate indices are refused', () => {
  assert.throws(() => combineShares([unsealed[0], unsealed[0]]), /Duplicate share index/);
});
