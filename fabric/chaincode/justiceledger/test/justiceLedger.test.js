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
function makeCtx({ msp = 'Org1MSP', seconds = 1791400000, nanos = 0, attrs = {}, id = 'x509::CN=user1::CN=ca' } = {}) {
  const state = new Map();
  const events = [];
  const validation = new Map();
  let txCount = 0;
  const stub = {
    createCompositeKey: (type, attrs) => `\u0000${type}\u0000${attrs.join('\u0000')}\u0000`,
    getState: async (key) => state.get(key) ?? Buffer.alloc(0),
    putState: async (key, value) => { state.set(key, Buffer.from(value)); },
    getTxTimestamp: () => ({ seconds: { toString: () => String(stub.seconds) }, nanos: stub.nanos }),
    getTxID: () => `tx${++txCount}`,
    setEvent: (name, payload) => events.push({ name, payload: payload.toString() }),
    setStateValidationParameter: async (key, policy) => { validation.set(key, Buffer.from(policy)); },
    getStateByPartialCompositeKey: async (type, attrs) => {
      // Like Fabric: an empty attribute list matches every key of the type.
      const prefix = `\u0000${type}\u0000${attrs.map((a) => `${a}\u0000`).join('')}`;
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
  const clientIdentity = {
    getMSPID: () => msp,
    getID: () => id,
    // Like fabric-shim: null for an attribute the certificate doesn't carry.
    getAttributeValue: (name) => attrs[name] ?? null,
  };
  return { stub, clientIdentity, events, validation };
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

test('WhoAmI reports an officer\'s org, role, unit and SIMULATED flag from the certificate', async () => {
  const ctx = makeCtx({
    msp: 'SimPoliceMSP',
    id: 'x509::CN=officer1::CN=ca.simpolice.example.com',
    attrs: { role: 'officer', unit: 'demo-unit', 'jc.simulated': 'true' },
  });
  assert.deepEqual(JSON.parse(await ledger.WhoAmI(ctx)), {
    mspId: 'SimPoliceMSP',
    id: 'x509::CN=officer1::CN=ca.simpolice.example.com',
    role: 'officer',
    unit: 'demo-unit',
    simulated: true,
  });
});

test('WhoAmI shows a missing role as null and simulated as false', async () => {
  const me = JSON.parse(await ledger.WhoAmI(makeCtx({ msp: 'Org1MSP' })));
  assert.equal(me.mspId, 'Org1MSP');
  assert.equal(me.role, null);
  assert.equal(me.simulated, false);
});

// --- Authority registry -----------------------------------------------------

const { KeyEndorsementPolicy } = require('fabric-shim');

const POLICE_KEY = Buffer.alloc(32, 7).toString('base64');
const POLICE_NAME = 'Demo Police Authority (SIMULATED)';

function adminCtx(overrides = {}) {
  return makeCtx({ msp: 'Org1MSP', attrs: { 'hf.Type': 'admin' }, ...overrides });
}

test('an Org1 admin registers SimPolice, and Org1 and Org2 peers must endorse later changes', async () => {
  const ctx = adminCtx();
  const record = JSON.parse(await ledger.RegisterAuthority(ctx, 'SimPoliceMSP', POLICE_NAME, POLICE_KEY, 'true'));
  assert.deepEqual(record, {
    mspId: 'SimPoliceMSP',
    name: POLICE_NAME,
    publicKey: POLICE_KEY,
    simulated: true,
    revoked: false,
    registeredAt: 1791400000,
    registeredBy: 'Org1MSP',
  });
  assert.equal(ctx.events[0].name, 'AuthorityRegistered');

  const key = ctx.stub.createCompositeKey('authority', ['SimPoliceMSP']);
  const policy = new KeyEndorsementPolicy(ctx.validation.get(key));
  assert.deepEqual(policy.listOrgs().sort(), ['Org1MSP', 'Org2MSP']);
});

test('only Org1 or Org2 admins may register or revoke', async () => {
  const outsiders = [
    makeCtx({ msp: 'Org1MSP', attrs: { 'hf.Type': 'client' } }),
    makeCtx({ msp: 'SimPoliceMSP', attrs: { 'hf.Type': 'admin' } }),
    makeCtx({ msp: 'SimPoliceMSP', attrs: { role: 'officer' } }),
  ];
  for (const ctx of outsiders) {
    await assert.rejects(
      ledger.RegisterAuthority(ctx, 'SimPoliceMSP', POLICE_NAME, POLICE_KEY, 'true'),
      /Only an admin of Org1MSP or Org2MSP/,
    );
    await assert.rejects(ledger.RevokeAuthority(ctx, 'SimPoliceMSP'), /Only an admin/);
  }
  const auditorAdmin = makeCtx({ msp: 'Org2MSP', attrs: { 'hf.Type': 'admin' } });
  const record = JSON.parse(await ledger.RegisterAuthority(auditorAdmin, 'SimPoliceMSP', POLICE_NAME, POLICE_KEY, 'true'));
  assert.equal(record.registeredBy, 'Org2MSP');
});

test('a simulated authority must say SIMULATED, and inputs are checked', async () => {
  const ctx = adminCtx();
  await assert.rejects(
    ledger.RegisterAuthority(ctx, 'SimPoliceMSP', 'Demo Police Authority', POLICE_KEY, 'true'),
    /must include "\(SIMULATED\)"/,
  );
  await assert.rejects(ledger.RegisterAuthority(ctx, 'SimPoliceMSP', POLICE_NAME, 'not-a-key', 'true'), /publicKey/);
  await assert.rejects(
    ledger.RegisterAuthority(ctx, 'SimPoliceMSP', POLICE_NAME, Buffer.alloc(31).toString('base64'), 'true'),
    /publicKey/,
  );
  await assert.rejects(ledger.RegisterAuthority(ctx, 'SimPoliceMSP', POLICE_NAME, POLICE_KEY, 'yes'), /simulated/);
  await assert.rejects(ledger.RegisterAuthority(ctx, 'Sim Police', POLICE_NAME, POLICE_KEY, 'true'), /mspId/);
  await assert.rejects(ledger.RegisterAuthority(ctx, 'SimPoliceMSP', '  ', POLICE_KEY, 'true'), /name/);
  await assert.rejects(
    ledger.RegisterAuthority(ctx, 'Org2MSP', 'Auditor (SIMULATED)', POLICE_KEY, 'true'),
    /runs the registry/,
  );
});

test('an active authority cannot be registered twice; a revoked one can come back', async () => {
  const ctx = adminCtx();
  await ledger.RegisterAuthority(ctx, 'SimPoliceMSP', POLICE_NAME, POLICE_KEY, 'true');
  await assert.rejects(
    ledger.RegisterAuthority(ctx, 'SimPoliceMSP', POLICE_NAME, POLICE_KEY, 'true'),
    /already registered/,
  );

  ctx.stub.seconds = 1791500000;
  const revoked = JSON.parse(await ledger.RevokeAuthority(ctx, 'SimPoliceMSP'));
  assert.equal(revoked.revoked, true);
  assert.equal(revoked.revokedAt, 1791500000);
  assert.equal(revoked.revokedBy, 'Org1MSP');
  await assert.rejects(ledger.RevokeAuthority(ctx, 'SimPoliceMSP'), /already revoked/);

  const again = JSON.parse(await ledger.RegisterAuthority(ctx, 'SimPoliceMSP', POLICE_NAME, POLICE_KEY, 'true'));
  assert.equal(again.revoked, false);
});

test('revoking an unknown authority fails', async () => {
  await assert.rejects(ledger.RevokeAuthority(adminCtx(), 'NobodyMSP'), /not a registered authority/);
});

test('GetAuthority and ListAuthorities are readable by any member and list only authorities', async () => {
  const ctx = adminCtx();
  await ledger.RegisterAuthority(ctx, 'SimPoliceMSP', POLICE_NAME, POLICE_KEY, 'true');
  await ledger.AnchorEvidence(ctx, HASH, CID, '1', NODE, APP_SIGNATURE);

  // An officer reading the same world state.
  const officer = makeCtx({ msp: 'SimPoliceMSP', attrs: { role: 'officer' } });
  officer.stub.getState = ctx.stub.getState;
  officer.stub.getStateByPartialCompositeKey = ctx.stub.getStateByPartialCompositeKey;

  const one = JSON.parse(await ledger.GetAuthority(officer, 'SimPoliceMSP'));
  assert.equal(one.found, true);
  assert.equal(one.publicKey, POLICE_KEY);
  assert.deepEqual(JSON.parse(await ledger.GetAuthority(officer, 'NobodyMSP')), { found: false, mspId: 'NobodyMSP' });
  assert.deepEqual(JSON.parse(await ledger.ListAuthorities(officer)).map((a) => a.mspId), ['SimPoliceMSP']);
});
