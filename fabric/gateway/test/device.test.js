'use strict';

// Run: npm test (in fabric/gateway)

const { test } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('crypto');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { createMailbox, pieceHashOf } = require('../mailbox');
const { createDeviceDesk, certificatePayload, setupPayload, piecePayload, nodeIdOf } = require('../device');

function makeKey() {
  const { publicKey, privateKey } = crypto.generateKeyPairSync('ed25519');
  const pub = publicKey.export({ format: 'der', type: 'spki' }).subarray(-32).toString('base64');
  return { pub, nodeId: nodeIdOf(pub), sign: (text) => crypto.sign(null, Buffer.from(text, 'utf8'), privateKey).toString('base64') };
}

const OWNER = makeKey();
const DEVICE = makeKey();
const GUARDIAN = '2b50591ed9986556';
const HASH = 'ab'.repeat(32);
const DEVICE_ADDRESS = '0xD9D08A9AEB67749A252FC0EC7AFA925E1467366F';
const DEVICE_X25519 = crypto.randomBytes(32).toString('base64');

function certificate(overrides = {}) {
  const cert = {
    deviceNodeId: DEVICE.nodeId,
    deviceEd25519: DEVICE.pub,
    deviceX25519: DEVICE_X25519,
    deviceAnchoringAddress: DEVICE_ADDRESS.toLowerCase(),
    ownerNodeId: OWNER.nodeId,
    issuedAt: 1000,
    ...overrides,
  };
  cert.signature = OWNER.sign(certificatePayload(cert));
  return cert;
}

function desk(ledgerOverrides = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'device-'));
  const mailbox = createMailbox(path.join(root, 'mailbox'));
  const ledger = {
    getNode: async (id) => (id === OWNER.nodeId ? { found: true, nodeId: id, ed25519PublicKey: OWNER.pub } : { found: false }),
    getGuardians: async () => ({ found: true, guardians: [GUARDIAN] }),
    verifyEvidence: async (hash) => ({
      found: true, manifestHash: hash, nodeId: DEVICE.nodeId, signer: DEVICE_ADDRESS.toLowerCase(), blockNumber: 283,
    }),
    ...ledgerOverrides,
  };
  return { desk: createDeviceDesk({ dir: path.join(root, 'setup'), ledger, mailbox }), mailbox };
}

function setupBody(signer = OWNER, overrides = {}) {
  const sealed = crypto.randomBytes(200).toString('base64');
  const body = { ownerNodeId: OWNER.nodeId, ownerEd25519: OWNER.pub, ownerX25519: 'eA==', issuedAt: 1000, sealed, ...overrides };
  body.signature = signer.sign(setupPayload(DEVICE.nodeId, body.ownerNodeId, body.issuedAt, body.sealed));
  return body;
}

function piece(overrides = {}) {
  const sealedShare = crypto.randomBytes(61).toString('base64');
  const pieceHash = pieceHashOf(sealedShare);
  return {
    manifestHash: HASH,
    victimNodeId: OWNER.nodeId,
    fromNodeId: DEVICE.nodeId,
    toNodeId: GUARDIAN,
    sealedShare,
    senderX25519: DEVICE_X25519,
    signature: DEVICE.sign(piecePayload(HASH, OWNER.nodeId, DEVICE.nodeId, GUARDIAN, pieceHash)),
    certificate: certificate(),
    share: { cid: 'QmX', quorum: 2 },
    ...overrides,
  };
}

test('the owner leaves her device a setup package and the device collects the newest', async () => {
  const { desk: d } = desk();
  assert.deepEqual(d.getSetup(DEVICE.nodeId), { found: false });
  await d.putSetup(DEVICE.nodeId, setupBody());
  await d.putSetup(DEVICE.nodeId, setupBody(OWNER, { issuedAt: 2000 }));
  const stored = d.getSetup(DEVICE.nodeId);
  assert.equal(stored.found, true);
  assert.equal(stored.issuedAt, 2000);
});

test('a setup package signed by someone else is refused', async () => {
  const { desk: d } = desk();
  await assert.rejects(d.putSetup(DEVICE.nodeId, setupBody(makeKey())), /not signed by the owner/);
  await assert.rejects(d.putSetup(DEVICE.nodeId, setupBody(OWNER, { ownerNodeId: 'f'.repeat(16) })), /not a registered node/);
});

test("a device's piece reaches the guardian's mailbox, marked as a device piece", async () => {
  const { desk: d, mailbox } = desk();
  await d.putPiece(piece());
  const [stored] = mailbox.list(GUARDIAN);
  assert.equal(stored.kind, 'device');
  assert.equal(stored.fromNodeId, DEVICE.nodeId);
  assert.equal(stored.blockNumber, 283);
  assert.equal(stored.certificate.ownerNodeId, OWNER.nodeId);
});

test('a piece without a valid owner certificate is refused', async () => {
  const { desk: d } = desk();
  const forged = certificate();
  forged.signature = makeKey().sign(certificatePayload(forged));
  await assert.rejects(d.putPiece(piece({ certificate: forged })), /certificate/);
});

test('a piece the device did not sign is refused', async () => {
  const { desk: d } = desk();
  await assert.rejects(d.putPiece(piece({ signature: makeKey().sign('x') })), /not signed by the device/);
});

test("pieces only go to the owner's guardians, for clips the device anchored", async () => {
  await assert.rejects(
    desk({ getGuardians: async () => ({ found: true, guardians: [] }) }).desk.putPiece(piece()),
    /guardian list/,
  );
  await assert.rejects(
    desk({ verifyEvidence: async () => ({ found: true, nodeId: '0'.repeat(16), signer: '0x0' }) }).desk.putPiece(piece()),
    /not anchored by this device/,
  );
});
