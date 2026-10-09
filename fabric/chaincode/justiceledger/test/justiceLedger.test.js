'use strict';

// Unit tests with an in-memory stand-in for the Fabric stub. Run: npm test

const { test } = require('node:test');
const assert = require('node:assert/strict');
const JusticeLedger = require('../lib/justiceLedger');

// Produced by the app's own signing code (AnchoringService.signAnchor) with
// Hardhat's public test account #0. The same values are checked on the Dart
// side in test/anchor_signature_vector_test.dart.
const DEVICE_ADDRESS = '0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266';
const HASH = '53f7a63576d0deb96daa84ac541364d061f43190d2a7a4204eeef6ffa49d290e';
const APP_SIGNATURE =
  '727f98f85eb303756a58d66cd6b6195dd812b7a221b760917525ee9b96ea0dd8' +
  '4f111e799e0079f6af1cbed11bfb856d5f7bfc3f110c251dd1dd5c124261d14c1b';
const OTHER_HASH = 'aa'.repeat(32);
const NODE = '0123456789abcdef';
const CID = 'bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi';

/** Minimal in-memory stub: composite keys, ordered partial queries, events. */
function makeCtx({ msp = 'Org1MSP', seconds = 1791400000, nanos = 0 } = {}) {
  const state = new Map();
  const events = [];
  let txCount = 0;
  const stub = {
    createCompositeKey: (type, attrs) => `\u0000${type}\u0000${attrs.join('\u0000')}\u0000`,
    getState: async (key) => state.get(key) ?? Buffer.alloc(0),
    putState: async (key, value) => { state.set(key, Buffer.from(value)); },
    getTxTimestamp: () => ({ seconds: { toString: () => String(stub.seconds) }, nanos: stub.nanos }),
    getTxID: () => `tx${++txCount}`,
    setEvent: (name, payload) => events.push({ name, payload: payload.toString() }),
    getStateByPartialCompositeKey: async (type, attrs) => {
      const prefix = `\u0000${type}\u0000${attrs.join('\u0000')}\u0000`;
      const rows = [...state.keys()].filter((k) => k.startsWith(prefix)).sort()
        .map((k) => ({ key: k, value: state.get(k) }));
      let i = 0;
      return {
        next: async () => (i < rows.length ? { value: rows[i++], done: false } : { done: true }),
        close: async () => {},
      };
    },
    seconds,
    nanos,
  };
  return { stub, clientIdentity: { getMSPID: () => msp }, events };
}

const ledger = new JusticeLedger();

test('signature made by the app recovers to the device address', async () => {
  const ctx = makeCtx();
  const record = JSON.parse(await ledger.AnchorEvidence(ctx, HASH, CID, '1791399990', NODE, APP_SIGNATURE));
  assert.equal(record.signer, DEVICE_ADDRESS);
  assert.equal(record.anchoredAt, 1791400000);
  assert.equal(record.capturedAt, 1791399990);
  assert.equal(ctx.events[0].name, 'EvidenceAnchored');
});

test('signature over a different hash records a signer that is not the device', async () => {
  const ctx = makeCtx();
  const record = JSON.parse(await ledger.AnchorEvidence(ctx, OTHER_HASH, CID, '1', NODE, APP_SIGNATURE));
  assert.notEqual(record.signer, DEVICE_ADDRESS);
});

test('malformed signatures are rejected', async () => {
  const ctx = makeCtx();
  await assert.rejects(ledger.AnchorEvidence(ctx, HASH, CID, '1', NODE, 'abcd'), /Signature must be 130/);
  await assert.rejects(ledger.AnchorEvidence(ctx, HASH, CID, '1', NODE, 'zz'.repeat(65)), /Signature must be 130/);
  await assert.rejects(ledger.AnchorEvidence(ctx, HASH, CID, '1', NODE, '00'.repeat(65)), /could not be recovered/);
});

test('duplicates are rejected, including 0x and uppercase spellings', async () => {
  const ctx = makeCtx();
  await ledger.AnchorEvidence(ctx, HASH, CID, '1', NODE, APP_SIGNATURE);
  await assert.rejects(ledger.AnchorEvidence(ctx, HASH, CID, '1', NODE, APP_SIGNATURE), /already stored/);
  await assert.rejects(
    ledger.AnchorEvidence(ctx, `0x${HASH.toUpperCase()}`, CID, '1', NODE, APP_SIGNATURE),
    /already stored/,
  );
});

test('empty CID, bad hash, bad node ID and bad capture time are rejected', async () => {
  const ctx = makeCtx();
  await assert.rejects(ledger.AnchorEvidence(ctx, HASH, '  ', '1', NODE, APP_SIGNATURE), /CID cannot be empty/);
  await assert.rejects(ledger.AnchorEvidence(ctx, 'abc', CID, '1', NODE, APP_SIGNATURE), /Manifest hash/);
  await assert.rejects(ledger.AnchorEvidence(ctx, HASH, CID, '1', 'xyz', APP_SIGNATURE), /Node ID/);
  await assert.rejects(ledger.AnchorEvidence(ctx, HASH, CID, '-5', NODE, APP_SIGNATURE), /capturedAt/);
});

test('only Org1MSP may anchor', async () => {
  const ctx = makeCtx({ msp: 'Org2MSP' });
  await assert.rejects(ledger.AnchorEvidence(ctx, HASH, CID, '1', NODE, APP_SIGNATURE), /Only Org1MSP/);
});

test('VerifyEvidence returns found: false for unknown hashes and the record otherwise', async () => {
  const ctx = makeCtx();
  assert.deepEqual(JSON.parse(await ledger.VerifyEvidence(ctx, HASH)), { found: false, manifestHash: HASH });
  await ledger.AnchorEvidence(ctx, HASH, CID, '1', NODE, APP_SIGNATURE);
  const found = JSON.parse(await ledger.VerifyEvidence(ctx, `0x${HASH}`));
  assert.equal(found.found, true);
  assert.equal(found.cid, CID);
  assert.equal(found.signer, DEVICE_ADDRESS);
});

test('GetEvidenceHistory lists a node\'s anchors in anchoring order', async () => {
  const ctx = makeCtx({ seconds: 2000 });
  await ledger.AnchorEvidence(ctx, OTHER_HASH, CID, '1', NODE, APP_SIGNATURE);
  ctx.stub.seconds = 1000; // an earlier transaction time sorts first
  await ledger.AnchorEvidence(ctx, HASH, CID, '1', NODE, APP_SIGNATURE);
  assert.deepEqual(JSON.parse(await ledger.GetEvidenceHistory(ctx, NODE)), [HASH, OTHER_HASH]);
  assert.deepEqual(JSON.parse(await ledger.GetEvidenceHistory(ctx, 'fedcba9876543210')), []);
});
