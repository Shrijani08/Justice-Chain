'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('crypto');
const { createAuth, createRateLimiter, requestPayload } = require('../auth');

function makeKey() {
  const { publicKey, privateKey } = crypto.generateKeyPairSync('ed25519');
  const pub = publicKey.export({ format: 'der', type: 'spki' }).subarray(-32).toString('base64');
  return {
    pub,
    nodeId: crypto.createHash('sha256').update(Buffer.from(pub, 'base64')).digest('hex').slice(0, 16),
    sign: (text) => crypto.sign(null, Buffer.from(text, 'utf8'), privateKey).toString('base64'),
  };
}

const NOW = 1_800_000_000;
const victim = makeKey();
const guardian = makeKey();
const stranger = makeKey();
const HASH = 'ab'.repeat(32);

const ledger = {
  getNode: async (id) => {
    const k = [victim, guardian, stranger].find((x) => x.nodeId === id);
    return k ? { found: true, ed25519PublicKey: k.pub } : { found: false };
  },
  getGuardians: async (id) => (id === victim.nodeId ? { found: true, guardians: [guardian.nodeId] } : { found: false }),
  getAccessRequest: async () => ({ found: true, victimNodeId: victim.nodeId }),
  verify: async () => ({ found: true, nodeId: 'ffffffffffffffff', claims: [{ nodeId: victim.nodeId }] }),
};

const auth = createAuth({ apiKey: 'k3y', ledger, now: () => NOW });

function signed(key, method, path, body = Buffer.alloc(0), { timestamp = NOW } = {}) {
  return {
    method,
    headers: {
      'x-node-id': key.nodeId,
      'x-timestamp': String(timestamp),
      'x-signature': key.sign(requestPayload(method, path, timestamp, body)),
    },
  };
}

test('a phone is recognised by its signature over the method, path, time and body', async () => {
  const body = Buffer.from('{"size":10}');
  assert.deepEqual(await auth.identify(signed(victim, 'POST', '/upload-url', body), '/upload-url', body),
    { kind: 'node', nodeId: victim.nodeId });
  // Another path, another body, or another key's signature is not that phone.
  assert.equal(await auth.identify(signed(victim, 'POST', '/upload-url', body), '/anchor', body), null);
  assert.equal(await auth.identify(signed(victim, 'POST', '/upload-url', body), '/upload-url', Buffer.from('{}')), null);
  const forged = signed(stranger, 'GET', '/history/x');
  forged.headers['x-node-id'] = victim.nodeId;
  assert.equal(await auth.identify(forged, '/history/x'), null);
});

test('an old or future timestamp, an unregistered phone or no headers is refused; the API key passes', async () => {
  assert.equal(await auth.identify(signed(victim, 'GET', '/x', undefined, { timestamp: NOW - 301 }), '/x'), null);
  assert.equal(await auth.identify(signed(victim, 'GET', '/x', undefined, { timestamp: NOW + 301 }), '/x'), null);
  assert.equal(await auth.identify(signed(makeKey(), 'GET', '/x'), '/x'), null);
  assert.equal(await auth.identify({ method: 'GET', headers: {} }, '/x'), null);
  assert.deepEqual(await auth.identify({ method: 'GET', headers: { 'x-api-key': 'k3y' } }, '/x'), { kind: 'key' });
  assert.equal(await auth.identify({ method: 'GET', headers: { 'x-api-key': 'wrong' } }, '/x'), null);
});

test("a phone reads only its own records and those of victims it guards", async () => {
  const as = (k) => ({ kind: 'node', nodeId: k.nodeId });
  const ok = (k, parts) => auth.authorize(as(k), 'GET', parts);
  const no = (k, parts) => assert.rejects(ok(k, parts), (e) => e.httpStatus === 403);

  await ok(victim, ['history', victim.nodeId]);
  await no(guardian, ['history', victim.nodeId]);
  await ok(guardian, ['pieces', guardian.nodeId]);
  await no(victim, ['pieces', guardian.nodeId]);

  for (const route of ['guardians', 'access-requests']) {
    await ok(victim, [route, victim.nodeId]);
    await ok(guardian, [route, victim.nodeId]);
    await no(stranger, [route, victim.nodeId]);
  }
  await ok(guardian, ['access-request', 'aa'.repeat(32)]);
  await no(stranger, ['access-request', 'aa'.repeat(32)]);

  // The audit trail follows whoever anchored the clip, including a later claim.
  await ok(victim, ['audit', HASH]);
  await ok(guardian, ['audit', HASH]);
  await no(stranger, ['audit', HASH]);

  await no(victim, ['device-setup', 'cccccccccccccccc']);
  await ok(stranger, ['verify', HASH]);
  await auth.authorize({ kind: 'key' }, 'GET', ['audit', HASH]);
});

test('the rate limiter refuses past the limit and resets with the window', () => {
  let t = 0;
  const take = createRateLimiter({ uploads: { max: 2, windowSeconds: 60 } }, () => t);
  take('uploads', 'a');
  take('uploads', 'a');
  assert.throws(() => take('uploads', 'a'), (e) => e.httpStatus === 429);
  take('uploads', 'b'); // per caller
  t = 60;
  take('uploads', 'a');
});
