'use strict';

// Unit tests with an in-memory stand-in for the Fabric stub. Run: npm test

const { test } = require('node:test');
const assert = require('node:assert/strict');
const nodeCrypto = require('crypto');
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

/**
 * Minimal in-memory stub: composite keys, ordered partial queries, events,
 * private data and transient data. Callers that pass the same [world] see
 * the same ledger, like different identities on one channel.
 */
function makeCtx({
  msp = 'Org1MSP', seconds = 1791400000, nanos = 0, attrs = {}, id = 'x509::CN=user1::CN=ca',
  world = { state: new Map(), privateData: new Map() }, transient = new Map(),
} = {}) {
  const { state, privateData } = world;
  const events = [];
  const validation = new Map();
  // One ID per context: every call within a transaction sees the same one.
  const txId = nodeCrypto.randomBytes(32).toString('hex');
  const stub = {
    createCompositeKey: (type, attrs) => `\u0000${type}\u0000${attrs.join('\u0000')}\u0000`,
    getState: async (key) => state.get(key) ?? Buffer.alloc(0),
    putState: async (key, value) => { state.set(key, Buffer.from(value)); },
    getPrivateData: async (collection, key) => privateData.get(`${collection}/${key}`) ?? Buffer.alloc(0),
    putPrivateData: async (collection, key, value) => { privateData.set(`${collection}/${key}`, Buffer.from(value)); },
    getTransient: () => transient,
    getPrivateDataByPartialCompositeKey: async (collection, type, attrs) => {
      const prefix = `${collection}/\u0000${type}\u0000${attrs.map((a) => `${a}\u0000`).join('')}`;
      const rows = [...privateData.keys()].filter((k) => k.startsWith(prefix)).sort()
        .map((k) => ({ key: k, value: privateData.get(k) }));
      let i = 0;
      // Like fabric-shim: private-data queries resolve to {iterator}.
      return {
        iterator: {
          next: async () => (i < rows.length ? { value: rows[i++], done: false } : { done: true }),
          close: async () => {},
        },
      };
    },
    getTxTimestamp: () => ({ seconds: { toString: () => String(stub.seconds) }, nanos: stub.nanos }),
    getTxID: () => txId,
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
  return { stub, clientIdentity, events, validation, world };
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

// --- Node registration, guardians, sharing with an authority ----------------

const { Wallet, getBytes } = require('ethers');

const sha256Hex = (data) => nodeCrypto.createHash('sha256').update(data).digest('hex');
const rawKey = (keyObject) => keyObject.export({ format: 'der', type: 'spki' }).subarray(-32).toString('base64');

/**
 * A phone's three keys, signing the way the app does: Ed25519 over the
 * payload's UTF-8 bytes (IdentityService.signBytes), and EIP-191 over the
 * 32 raw bytes of a SHA-256 (AnchoringService.signAnchor).
 */
function makePhone(seed) {
  const wallet = new Wallet(`0x${sha256Hex(`wallet-${seed}`)}`);
  const ed = nodeCrypto.generateKeyPairSync('ed25519');
  const edPub = rawKey(ed.publicKey);
  const signHash = (hashHex) => wallet.signMessageSync(getBytes(`0x${hashHex}`)).slice(2);
  return {
    nodeId: sha256Hex(Buffer.from(edPub, 'base64')).slice(0, 16),
    edPub,
    xPub: rawKey(nodeCrypto.generateKeyPairSync('x25519').publicKey),
    address: wallet.address.toLowerCase(),
    edSign: (payload) => nodeCrypto.sign(null, Buffer.from(payload, 'utf8'), ed.privateKey).toString('base64'),
    sign: (payload) => signHash(sha256Hex(Buffer.from(payload, 'utf8'))),
    signHash,
  };
}

function registerPayload(p) {
  return `justice-chain/register-node/v1|${p.nodeId}|${p.edPub}|${p.xPub}|${p.address}`;
}

function register(ctx, phone) {
  const payload = registerPayload(phone);
  return ledger.RegisterNode(ctx, phone.nodeId, phone.edPub, phone.xPub, phone.address,
    phone.edSign(payload), phone.sign(payload));
}

function guardiansPayload(victim, seq, ids) {
  return `justice-chain/set-guardians/v1|${victim.nodeId}|${seq}|${[...ids].sort().join(',')}`;
}

test('a phone registers its node ID and keys, signed by both of its keys', async () => {
  const ctx = makeCtx();
  const phone = makePhone('victim');
  const record = JSON.parse(await register(ctx, phone));
  assert.deepEqual(record, {
    nodeId: phone.nodeId,
    ed25519PublicKey: phone.edPub,
    x25519PublicKey: phone.xPub,
    anchoringAddress: phone.address,
    registeredAt: 1791400000,
  });
  assert.equal(ctx.events[0].name, 'NodeRegistered');
  assert.deepEqual(JSON.parse(await ledger.GetNode(ctx, phone.nodeId)), { found: true, ...record });
  assert.deepEqual(JSON.parse(await ledger.GetNode(ctx, 'fedcba9876543210')), { found: false, nodeId: 'fedcba9876543210' });

  // Repeating the same registration is harmless; other keys for the ID are refused.
  assert.deepEqual(JSON.parse(await register(ctx, phone)), record);
  const impostor = { ...makePhone('impostor'), nodeId: phone.nodeId, edPub: phone.edPub, edSign: phone.edSign };
  await assert.rejects(register(ctx, impostor), /already registered with different keys/);
});

test('a registration is refused unless both keys signed it and the ID matches the key', async () => {
  const ctx = makeCtx();
  const phone = makePhone('victim');
  const other = makePhone('other');
  const payload = registerPayload(phone);
  const reg = (overrides) => {
    const a = { ...phone, edSig: phone.edSign(payload), anchorSig: phone.sign(payload), ...overrides };
    return ledger.RegisterNode(ctx, a.nodeId, a.edPub, a.xPub, a.address, a.edSig, a.anchorSig);
  };
  await assert.rejects(reg({ nodeId: other.nodeId }), /does not match the Ed25519 public key/);
  await assert.rejects(reg({ edSig: other.edSign(payload) }), /Ed25519 signature/);
  await assert.rejects(reg({ edSig: 'AAAA' }), /Ed25519 signature/);
  await assert.rejects(reg({ anchorSig: other.sign(payload) }), /Anchoring signature/);
  await assert.rejects(reg({ xPub: other.xPub }), /Ed25519 signature/); // the payload covers every key
  await assert.rejects(reg({ address: 'xyz' }), /Anchoring address/);
  await assert.rejects(register(makeCtx({ msp: 'Org2MSP' }), phone), /Only Org1MSP may register nodes/);
});

test('the victim sets guardians with a growing sequence, signed by their anchoring key', async () => {
  const ctx = makeCtx();
  const [victim, g1, g2] = ['victim', 'g1', 'g2'].map(makePhone);
  for (const p of [victim, g1, g2]) await register(ctx, p);

  const ids = [g2.nodeId, g1.nodeId];
  const set = (seq, list, signer = victim) =>
    ledger.SetGuardians(ctx, victim.nodeId, JSON.stringify(list), String(seq), signer.sign(guardiansPayload(victim, seq, list)));

  const record = JSON.parse(await set(1, ids));
  assert.deepEqual(record.guardians, [...ids].sort());
  assert.equal(record.sequence, 1);
  assert.deepEqual(JSON.parse(await ledger.GetGuardians(ctx, victim.nodeId)), { found: true, ...record });

  await assert.rejects(set(1, [g1.nodeId]), /sequence must be greater than 1/); // replay of an old number
  await assert.rejects(set(2, [g1.nodeId], g1), /not from the victim/);
  assert.deepEqual(JSON.parse(await set(2, [g1.nodeId])).guardians, [g1.nodeId]);

  await assert.rejects(set(3, [makePhone('stranger').nodeId]), /Guardian .* is not a registered node/);
  await assert.rejects(set(3, [victim.nodeId]), /own guardian/);
  await assert.rejects(set(3, [g1.nodeId, g1.nodeId]), /duplicates/);
  await assert.rejects(ledger.SetGuardians(ctx, victim.nodeId, 'not json', '3', victim.sign('x')), /JSON array/);
  const unregistered = makePhone('unregistered');
  await assert.rejects(
    ledger.SetGuardians(ctx, unregistered.nodeId, '[]', '1', unregistered.sign(guardiansPayload(unregistered, 1, []))),
    /Victim .* is not a registered node/,
  );
});

/** A registered victim with an anchored clip, and SimPolice registered as an authority. */
async function sharingSetup() {
  const world = { state: new Map(), privateData: new Map() };
  const gateway = makeCtx({ world });
  const victim = makePhone('victim');
  await register(gateway, victim);
  await ledger.AnchorEvidence(gateway, HASH, CID, '1', victim.nodeId, victim.signHash(HASH));
  await ledger.RegisterAuthority(makeCtx({ world, attrs: { 'hf.Type': 'admin' } }),
    'SimPoliceMSP', POLICE_NAME, POLICE_KEY, 'true');
  const sealedShare = nodeCrypto.randomBytes(61).toString('base64');
  return { world, victim, sealedShare };
}

function shareConsent(victim, { hash = HASH, msp = 'SimPoliceMSP', x = 3, t = 2, sealedShare }) {
  const shareHash = sha256Hex(Buffer.from(sealedShare, 'base64'));
  return victim.sign(`justice-chain/share-with-authority/v1|${hash}|${msp}|${x}|${t}|${shareHash}`);
}

function share(world, victim, sealedShare, { msp = 'SimPoliceMSP', x = 3, t = 2, consent, submitter = 'Org1MSP' } = {}) {
  const ctx = makeCtx({ world, msp: submitter, transient: new Map([['sealedShare', Buffer.from(sealedShare)]]) });
  const signature = consent ?? shareConsent(victim, { msp, x, t, sealedShare });
  return { ctx, result: ledger.ShareWithAuthority(ctx, HASH, msp, String(x), String(t), signature) };
}

test('the victim shares one sealed piece: private data for SimPolice, only consent and hash in public', async () => {
  const { world, victim, sealedShare } = await sharingSetup();
  const { ctx, result } = share(world, victim, sealedShare);
  const consent = JSON.parse(await result);

  assert.equal(consent.manifestHash, HASH);
  assert.equal(consent.authorityMsp, 'SimPoliceMSP');
  assert.equal(consent.victimNodeId, victim.nodeId);
  assert.equal(consent.shareHash, sha256Hex(Buffer.from(sealedShare, 'base64')));
  assert.equal(ctx.events[0].name, 'SharedWithAuthority');

  // The sealed piece is only in SimPolice's collection, never in public state or the event.
  const piece = JSON.parse(world.privateData.get(`authorityShares_SimPolice/${HASH}`).toString());
  assert.equal(piece.sealedShare, sealedShare);
  assert.equal(piece.senderX25519PublicKey, victim.xPub);
  assert.equal(piece.shareX, 3);
  assert.equal(piece.threshold, 2);
  const publicText = [...world.state.values()].map((v) => v.toString()).join('\n') + ctx.events[0].payload;
  assert.equal(publicText.includes(sealedShare), false);

  assert.deepEqual(JSON.parse(await ledger.ListAuthorityShares(makeCtx({ world }), 'SimPoliceMSP')), [consent]);
  await assert.rejects(share(world, victim, sealedShare).result, /already shared with SimPoliceMSP/);
});

test('sharing is refused without consent for exactly this piece, index and authority', async () => {
  const { world, victim, sealedShare } = await sharingSetup();
  const swapped = nodeCrypto.randomBytes(61).toString('base64');

  // Consent signed for another piece, another authority, another index, or by someone else.
  await assert.rejects(
    share(world, victim, swapped, { consent: shareConsent(victim, { sealedShare }) }).result, /Consent is not signed/);
  await assert.rejects(
    share(world, victim, sealedShare, { consent: shareConsent(victim, { msp: 'OtherMSP', sealedShare }) }).result,
    /Consent is not signed/);
  await assert.rejects(
    share(world, victim, sealedShare, { consent: shareConsent(victim, { x: 4, sealedShare }) }).result, /Consent is not signed/);
  await assert.rejects(
    share(world, victim, sealedShare, { consent: shareConsent(makePhone('other'), { sealedShare }) }).result,
    /Consent is not signed/);

  await assert.rejects(share(world, victim, 'AAAA').result, /Transient sealedShare/);
  await assert.rejects(share(world, victim, sealedShare, { submitter: 'SimPoliceMSP' }).result, /Only Org1MSP may share/);
  await assert.rejects(share(world, victim, sealedShare, { msp: 'NobodyMSP' }).result, /not an active registered authority/);
  await assert.rejects(share(world, victim, sealedShare, { x: 0 }).result, /shareX/);
  assert.equal(world.privateData.size, 0);
});

test('sharing needs an anchored clip from the same registered victim and an active authority', async () => {
  const { world, victim, sealedShare } = await sharingSetup();

  const gateway = makeCtx({ world });
  const ctxFor = () => makeCtx({ world, transient: new Map([['sealedShare', Buffer.from(sealedShare)]]) });
  const consentFor = (hash) => victim.sign(
    `justice-chain/share-with-authority/v1|${hash}|SimPoliceMSP|3|2|${sha256Hex(Buffer.from(sealedShare, 'base64'))}`);

  // A clip nobody anchored.
  await assert.rejects(
    ledger.ShareWithAuthority(ctxFor(), OTHER_HASH, 'SimPoliceMSP', '3', '2', consentFor(OTHER_HASH)), /not anchored/);

  // A clip anchored under the victim's node ID but signed by another key.
  const thirdHash = 'bb'.repeat(32);
  await ledger.AnchorEvidence(gateway, thirdHash, CID, '1', victim.nodeId, makePhone('thief').signHash(thirdHash));
  await assert.rejects(
    ledger.ShareWithAuthority(ctxFor(), thirdHash, 'SimPoliceMSP', '3', '2', consentFor(thirdHash)),
    /not anchored by its node.s registered key/);

  // A revoked authority.
  await ledger.RevokeAuthority(makeCtx({ world, attrs: { 'hf.Type': 'admin' } }), 'SimPoliceMSP');
  await assert.rejects(share(world, victim, sealedShare).result, /not an active registered authority/);
});

test('only an officer of the authority reads the shared piece', async () => {
  const { world, victim, sealedShare } = await sharingSetup();
  await share(world, victim, sealedShare).result;

  const officer = makeCtx({ world, msp: 'SimPoliceMSP', attrs: { role: 'officer' } });
  const piece = JSON.parse(await ledger.GetAuthorityShare(officer, HASH));
  assert.equal(piece.found, true);
  assert.equal(piece.sealedShare, sealedShare);
  assert.deepEqual(JSON.parse(await ledger.GetAuthorityShare(officer, OTHER_HASH)), { found: false, manifestHash: OTHER_HASH });

  const outsiders = [
    makeCtx({ world, msp: 'SimPoliceMSP', attrs: { role: 'supervisor' } }),
    makeCtx({ world, msp: 'SimPoliceMSP' }),
    makeCtx({ world, msp: 'Org2MSP', attrs: { role: 'officer' } }),
    makeCtx({ world, msp: 'Org1MSP', attrs: { 'hf.Type': 'admin' } }),
  ];
  for (const ctx of outsiders) {
    await assert.rejects(ledger.GetAuthorityShare(ctx, HASH), /Only an active registered authority's officer may do this/);
  }
});

// --- Access requests, releases and the audit trail --------------------------

const OFFICER = {
  msp: 'SimPoliceMSP',
  attrs: { role: 'officer' },
  id: 'x509::/C=IN/O=SimPolice (SIMULATED)/OU=client/CN=officer1::/C=IN/CN=ca.simpolice.example.com',
};
const SUPERVISOR = {
  msp: 'SimPoliceMSP',
  attrs: { role: 'supervisor' },
  id: 'x509::/C=IN/O=SimPolice (SIMULATED)/OU=client/CN=supervisor1::/C=IN/CN=ca.simpolice.example.com',
};

/**
 * A clip shared with SimPolice (piece 3), a victim with guardian g1, and a
 * registered stranger. Every call gets its own context and a later
 * transaction time, like separate transactions on the channel.
 */
async function custodySetup() {
  const { world, victim, sealedShare } = await sharingSetup();
  let seconds = 1791400100;
  const as = (who = {}, transient) => makeCtx({ world, seconds: seconds++, ...who, transient });
  const [g1, g2, stranger] = ['g1', 'g2', 'stranger'].map(makePhone);
  for (const p of [g1, g2, stranger]) await register(as(), p);
  await ledger.SetGuardians(as(), victim.nodeId, JSON.stringify([g1.nodeId, g2.nodeId]), '1',
    victim.sign(guardiansPayload(victim, 1, [g1.nodeId, g2.nodeId])));
  await share(world, victim, sealedShare).result;
  return { world, as, victim, g1, g2, stranger };
}

function releaseSignature(releaser, request, x, pieceHash) {
  return releaser.sign(
    `justice-chain/release-share/v1|${request.requestId}|${request.manifestHash}|${request.authorityMsp}|${x}|${pieceHash}`);
}

/** Signs and submits a release, then delivers the piece, like the gateway's POST /releases. */
async function release(as, request, releaser, x, { signer = releaser, piece } = {}) {
  const sealed = piece ?? nodeCrypto.randomBytes(61).toString('base64');
  const pieceHash = sha256Hex(Buffer.from(sealed, 'base64'));
  const approved = JSON.parse(await ledger.ReleaseShare(as(), request.requestId, releaser.nodeId, String(x), pieceHash,
    releaseSignature(signer, request, x, pieceHash)));
  const delivery = JSON.parse(await ledger.DeliverReleasedShare(
    as({}, new Map([['sealedShare', Buffer.from(sealed)]])), request.requestId));
  return { approved, delivery, sealed };
}

test('an officer requests access to a shared clip; JusticeChain and the Auditor must endorse any change', async () => {
  const { as, victim } = await custodySetup();
  const ctx = as(OFFICER);
  const request = JSON.parse(await ledger.RequestAccess(ctx, HASH, 'Assault report, demo case', 'DEMO-001'));
  assert.equal(request.status, 'open');
  assert.equal(request.requestedBy, 'officer1');
  assert.equal(request.victimNodeId, victim.nodeId);
  assert.equal(request.heldShareX, 3);
  assert.equal(request.requestId, ctx.stub.getTxID());

  const key = ctx.stub.createCompositeKey('accessRequest', [request.requestId]);
  assert.deepEqual(new KeyEndorsementPolicy(ctx.validation.get(key)).listOrgs().sort(), ['Org1MSP', 'Org2MSP']);
  assert.deepEqual(JSON.parse(await ledger.ListAccessRequests(as(), victim.nodeId)), [request]);
  assert.deepEqual(JSON.parse(await ledger.GetAccessRequest(as(), request.requestId)), { found: true, ...request });
});

test('only an officer may request, and only for a clip shared with their authority', async () => {
  const { as } = await custodySetup();
  for (const who of [SUPERVISOR, {}, { msp: 'Org2MSP', attrs: { role: 'officer' } }]) {
    await assert.rejects(ledger.RequestAccess(as(who), HASH, 'reason', 'REF'), /officer may do this/);
  }
  await assert.rejects(ledger.RequestAccess(as(OFFICER), OTHER_HASH, 'reason', 'REF'), /not shared with SimPoliceMSP/);
  await assert.rejects(ledger.RequestAccess(as(OFFICER), HASH, ' ', 'REF'), /reason/);
  await assert.rejects(ledger.RequestAccess(as(OFFICER), HASH, 'reason', ''), /caseRef/);
});

test('a registered guardian releases their own piece; the officer then holds two pieces', async () => {
  const { as, world, g1 } = await custodySetup();
  const request = JSON.parse(await ledger.RequestAccess(as(OFFICER), HASH, 'reason', 'DEMO-002'));
  const { approved, delivery, sealed } = await release(as, request, g1, 1);

  assert.equal(approved.status, 'released');
  assert.equal(approved.releaserRole, 'guardian');
  assert.equal(approved.releasedBy, g1.nodeId);
  assert.equal(approved.releasedShareX, 1);
  assert.equal(delivery.shareHash, approved.releasedShareHash);
  // The approval and the public state never carry the piece itself.
  assert.equal([...world.state.values()].some((v) => v.toString().includes(sealed)), false);

  const pieces = JSON.parse(await ledger.GetAuthorityShare(as(OFFICER), HASH));
  assert.equal(pieces.shareX, 3);
  assert.equal(pieces.released.length, 1);
  assert.equal(pieces.released[0].shareX, 1);
  assert.equal(pieces.released[0].sealedShare, sealed);
  assert.equal(pieces.released[0].senderX25519PublicKey, g1.xPub);
  assert.equal(pieces.released[0].releaserRole, 'guardian');
});

test('the victim can release instead, with a new piece', async () => {
  const { as, victim } = await custodySetup();
  const request = JSON.parse(await ledger.RequestAccess(as(OFFICER), HASH, 'reason', 'DEMO-003'));
  const { approved } = await release(as, request, victim, 4);
  assert.equal(approved.releaserRole, 'victim');
  const pieces = JSON.parse(await ledger.GetAuthorityShare(as(OFFICER), HASH));
  assert.equal(pieces.released[0].senderX25519PublicKey, victim.xPub);
});

test('a release needs a valid signature from the victim or a registered guardian, sent by JusticeChain', async () => {
  const { as, g1, g2, stranger } = await custodySetup();
  const request = JSON.parse(await ledger.RequestAccess(as(OFFICER), HASH, 'reason', 'DEMO-004'));
  const pieceHash = sha256Hex(nodeCrypto.randomBytes(61));
  const tryRelease = (who, releaser, x, signer = releaser) => ledger.ReleaseShare(
    as(who), request.requestId, releaser.nodeId, String(x), pieceHash, releaseSignature(signer, request, x, pieceHash));

  // The officer can't approve their own request, nor can the Auditor.
  await assert.rejects(tryRelease(OFFICER, g1, 1), /Only Org1MSP may release/);
  await assert.rejects(tryRelease({ msp: 'Org2MSP' }, g1, 1), /Only Org1MSP may release/);
  // A registered node that isn't a guardian, a guardian ID with someone else's signature.
  await assert.rejects(tryRelease({}, stranger, 1), /Only the victim or one of their registered guardians/);
  await assert.rejects(tryRelease({}, g1, 1, g2), /not signed by the releaser/);
  // A signature for another piece index.
  await assert.rejects(
    ledger.ReleaseShare(as(), request.requestId, g1.nodeId, '2', pieceHash, releaseSignature(g1, request, 1, pieceHash)),
    /not signed by the releaser/);
  // The piece SimPolice already holds.
  await assert.rejects(tryRelease({}, g1, 3), /already holds piece 3/);
  await assert.rejects(
    ledger.ReleaseShare(as(), 'ab'.repeat(32), g1.nodeId, '1', pieceHash, releaseSignature(g1, request, 1, pieceHash)),
    /not found/);

  const ok = JSON.parse(await tryRelease({}, g1, 1));
  assert.equal(ok.status, 'released');
  await assert.rejects(tryRelease({}, g2, 2), /already released/);
});

test('only the approved piece is delivered, once', async () => {
  const { as, g1 } = await custodySetup();
  const request = JSON.parse(await ledger.RequestAccess(as(OFFICER), HASH, 'reason', 'DEMO-005'));
  const piece = nodeCrypto.randomBytes(61).toString('base64');
  const deliver = (sealed, who = {}) => ledger.DeliverReleasedShare(
    as(who, new Map([['sealedShare', Buffer.from(sealed)]])), request.requestId);

  await assert.rejects(deliver(piece), /has not been released/);
  const pieceHash = sha256Hex(Buffer.from(piece, 'base64'));
  await ledger.ReleaseShare(as(), request.requestId, g1.nodeId, '1', pieceHash, releaseSignature(g1, request, 1, pieceHash));
  await assert.rejects(deliver(nodeCrypto.randomBytes(61).toString('base64')), /does not match the one that was released/);
  await assert.rejects(deliver(piece, OFFICER), /Only Org1MSP may deliver/);
  await deliver(piece);
  await assert.rejects(deliver(piece), /already delivered/);
});

test('the audit trail records shared, requested, released and opened, readable by JusticeChain, the Auditor and a supervisor', async () => {
  const { as, g1 } = await custodySetup();
  await assert.rejects(ledger.RecordAccess(as(OFFICER), HASH, 'opened', ''), /No released access request/);

  const request = JSON.parse(await ledger.RequestAccess(as(OFFICER), HASH, 'Assault report', 'DEMO-006'));
  await release(as, request, g1, 1);
  await ledger.RecordAccess(as(OFFICER), HASH, 'opened', 'Viewed in the officer portal');
  await assert.rejects(ledger.RecordAccess(as(OFFICER), HASH, 'deleted', ''), /action must be one of/);
  await assert.rejects(ledger.RecordAccess(as(SUPERVISOR), HASH, 'opened', ''), /officer may do this/);

  for (const reader of [{}, { msp: 'Org2MSP' }, SUPERVISOR]) {
    const trail = JSON.parse(await ledger.GetAuditTrail(as(reader), HASH));
    assert.deepEqual(trail.map((e) => e.event), ['shared', 'requested', 'released', 'opened']);
  }
  const trail = JSON.parse(await ledger.GetAuditTrail(as({ msp: 'Org2MSP' }), HASH));
  assert.equal(trail[1].actor.name, 'officer1');
  assert.equal(trail[1].detail.caseRef, 'DEMO-006');
  assert.deepEqual(trail[2].actor, { nodeId: g1.nodeId, role: 'guardian' });
  assert.equal(trail[3].detail.note, 'Viewed in the officer portal');

  await assert.rejects(ledger.GetAuditTrail(as(OFFICER), HASH), /supervisor may do this/);
});
