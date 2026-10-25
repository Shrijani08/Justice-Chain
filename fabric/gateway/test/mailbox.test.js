'use strict';

// Run: npm test (in fabric/gateway)

const { test } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('crypto');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { createMailbox, ackPayload, pieceHashOf } = require('../mailbox');

const RECIPIENT = '2b50591ed9986556';

function makeKey() {
  const { publicKey, privateKey } = crypto.generateKeyPairSync('ed25519');
  return {
    pub: publicKey.export({ format: 'der', type: 'spki' }).subarray(-32).toString('base64'),
    sign: (text) => crypto.sign(null, Buffer.from(text, 'utf8'), privateKey).toString('base64'),
  };
}

function envelope(overrides = {}) {
  const sealedShare = crypto.randomBytes(61).toString('base64');
  return {
    manifestHash: 'ab'.repeat(32),
    victimNodeId: '936a0719779c2296',
    fromNodeId: '1111222233334444',
    toNodeId: RECIPIENT,
    pieceHash: pieceHashOf(sealedShare),
    sealedShare,
    forwardedAt: 1792833000,
    ...overrides,
  };
}

const freshMailbox = () => createMailbox(fs.mkdtempSync(path.join(os.tmpdir(), 'mailbox-')));

test('a forwarded piece waits for its recipient; a retry overwrites instead of duplicating', () => {
  const mailbox = freshMailbox();
  const env = envelope();
  const stored = mailbox.put(env);
  assert.match(stored.id, /^[0-9a-f]{32}$/);
  assert.equal(mailbox.put(env).id, stored.id);
  assert.deepEqual(mailbox.list(RECIPIENT), [stored]);
  assert.deepEqual(mailbox.list('ffffffffffffffff'), []);
});

test('only the recipient\'s signature deletes envelopes', () => {
  const mailbox = freshMailbox();
  const recipient = makeKey();
  const other = makeKey();
  const { id } = mailbox.put(envelope());

  assert.throws(() => mailbox.ack(RECIPIENT, [id], other.sign(ackPayload(RECIPIENT, [id])), recipient.pub), /not signed/);
  assert.throws(() => mailbox.ack(RECIPIENT, [id], recipient.sign(ackPayload(RECIPIENT, [id])), null), /not signed/);
  assert.throws(() => mailbox.ack(RECIPIENT, ['../x'], 'sig', recipient.pub), /envelope IDs/);
  assert.equal(mailbox.list(RECIPIENT).length, 1);

  assert.deepEqual(mailbox.ack(RECIPIENT, [id], recipient.sign(ackPayload(RECIPIENT, [id])), recipient.pub), { deleted: 1 });
  assert.deepEqual(mailbox.list(RECIPIENT), []);
});

test('bad node IDs and pieces that are not base64 are refused', () => {
  const mailbox = freshMailbox();
  assert.throws(() => mailbox.list('../../etc'), /16 hex/);
  assert.throws(() => mailbox.put(envelope({ toNodeId: '../evil' })), /16 hex/);
  assert.throws(() => pieceHashOf('not base64!'), /base64/);
});
