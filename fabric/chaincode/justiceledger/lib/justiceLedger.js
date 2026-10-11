'use strict';

/**
 * Immutable chain-of-custody anchors for encrypted distress evidence, on
 * Hyperledger Fabric. A port of contracts/JusticeLedger.sol: the ledger
 * never sees video, keys, or anything identifying a victim by name, only a
 * manifest hash, an IPFS CID, and the capturing device's signature.
 *
 * As on the EVM, authorship comes from whichever address the device
 * signature recovers to, not from who submits: the JusticeChain gateway
 * submits for every phone, but it can't forge a device's signature. The
 * chaincode records the recovered signer. Anchors don't require a
 * registered node; phones that register (RegisterNode) let the chaincode
 * tie a node ID to its keys, which consents and key releases rely on.
 */

const crypto = require('crypto');
const { Contract } = require('fabric-contract-api');
const { KeyEndorsementPolicy } = require('fabric-shim');
const { getBytes, verifyMessage } = require('ethers');

// Only JusticeChainOrg's gateway submits anchors on behalf of phones.
const ANCHORING_MSP = 'Org1MSP';

// Each authority's sealed key pieces live in its own private data
// collection (fabric/network/collections_config.json), shared only with
// JusticeChainOrg; the channel ledger holds just a hash of each entry.
const AUTHORITY_COLLECTIONS = { SimPoliceMSP: 'authorityShares_SimPolice' };

const MAX_GUARDIANS = 10;

// A Shamir piece sealed as the app does: nonce(12) + mac(16) + AES-GCM of
// [x] ++ 32-byte key piece.
const SEALED_SHARE_BYTES = 12 + 16 + 1 + 32;

// What a phone signs for each action is domain-separated and versioned, so
// a signature made for one action can never be replayed as another.
const ACTION_REGISTER_NODE = 'justice-chain/register-node/v1';
const ACTION_SET_GUARDIANS = 'justice-chain/set-guardians/v1';
const ACTION_SHARE_WITH_AUTHORITY = 'justice-chain/share-with-authority/v1';

// DER prefix that turns a raw 32-byte Ed25519 key into an SPKI key.
const ED25519_SPKI_PREFIX = Buffer.from('302a300506032b6570032100', 'hex');

function sha256Hex(data) {
  return crypto.createHash('sha256').update(data).digest('hex');
}

function requireSubmitter(ctx, msp, action) {
  const caller = ctx.clientIdentity.getMSPID();
  if (caller !== msp) {
    throw new Error(`Only ${msp} may ${action}, not ${caller}`);
  }
}

/** A raw 32-byte key in standard base64, as the app stores keys. */
function normaliseRawKey(value, label) {
  const text = String(value ?? '').trim();
  const bytes = Buffer.from(text, 'base64');
  if (bytes.length !== 32 || bytes.toString('base64') !== text) {
    throw new Error(`${label} must be a base64 32-byte key`);
  }
  return text;
}

/** An Ethereum-style address, lowercase with 0x, or throws. */
function normaliseAddress(value) {
  return `0x${normaliseHex(value, 40, 'Anchoring address')}`;
}

/**
 * The address that signed [payload] as the app's AnchoringService
 * .signAnchor does: EIP-191 over the 32 raw bytes of the payload's SHA-256.
 */
function recoverActionSigner(payload, signature) {
  return recoverSigner(sha256Hex(Buffer.from(payload, 'utf8')), signature);
}

/** Whether [signatureB64] is the Ed25519 key's signature over [payload]'s UTF-8 bytes. */
function verifyEd25519(publicKeyB64, payload, signatureB64) {
  const signature = Buffer.from(String(signatureB64 ?? ''), 'base64');
  if (signature.length !== 64) return false;
  const key = crypto.createPublicKey({
    key: Buffer.concat([ED25519_SPKI_PREFIX, Buffer.from(publicKeyB64, 'base64')]),
    format: 'der',
    type: 'spki',
  });
  return crypto.verify(null, Buffer.from(payload, 'utf8'), key, signature);
}

async function readJson(ctx, key) {
  const data = await ctx.stub.getState(key);
  return data && data.length > 0 ? JSON.parse(data.toString('utf8')) : null;
}

async function requireNode(ctx, nodeId, label) {
  const node = await readJson(ctx, ctx.stub.createCompositeKey('node', [nodeId]));
  if (!node) {
    throw new Error(`${label} ${nodeId} is not a registered node`);
  }
  return node;
}

// Admins of JusticeChainOrg and the Auditor manage the authority registry,
// and both orgs' peers must endorse any later change to an entry, so
// neither can register, swap the key of, or revoke an authority alone.
const REGISTRY_MSPS = ['Org1MSP', 'Org2MSP'];

function requireRegistryAdmin(ctx) {
  const msp = ctx.clientIdentity.getMSPID();
  if (!REGISTRY_MSPS.includes(msp) || ctx.clientIdentity.getAttributeValue('hf.Type') !== 'admin') {
    throw new Error(`Only an admin of ${REGISTRY_MSPS.join(' or ')} may change the authority registry`);
  }
  return msp;
}

function normaliseMspId(value) {
  const mspId = String(value ?? '').trim();
  if (!/^[A-Za-z0-9.-]{1,64}$/.test(mspId)) {
    throw new Error('mspId must be 1-64 letters, digits, dots or hyphens');
  }
  return mspId;
}

/** Lowercase, no 0x, exactly [length] hex characters, or throws. */
function normaliseHex(value, length, label) {
  const hex = String(value ?? '').trim().toLowerCase().replace(/^0x/, '');
  if (hex.length !== length || !/^[0-9a-f]+$/.test(hex)) {
    throw new Error(`${label} must be ${length} hex characters`);
  }
  return hex;
}

/**
 * The address that signed [manifestHash], lowercase with 0x. The app signs
 * the 32 raw hash bytes with EIP-191 "personal sign" (AnchoringService
 * .signAnchor), so the hash must be passed as bytes here: as a string,
 * ethers would hash its 64 characters instead and recover a wrong address.
 */
function recoverSigner(manifestHash, signature) {
  const sig = normaliseHex(signature, 130, 'Signature');
  try {
    return verifyMessage(getBytes(`0x${manifestHash}`), `0x${sig}`).toLowerCase();
  } catch (e) {
    throw new Error('Signature could not be recovered');
  }
}

/**
 * The transaction's timestamp, identical on every endorsing peer. Unlike an
 * EVM block.timestamp it comes from the submitting client's transaction
 * header, i.e. the JusticeChain gateway's clock, so it is only as
 * trustworthy as the gateway; the independent evidence of ordering is the
 * block the transaction commits in. Never use the peer's own clock instead:
 * endorsements from different peers must produce byte-identical results.
 */
function txTime(ctx) {
  const ts = ctx.stub.getTxTimestamp();
  const seconds = Number(ts.seconds.toString());
  const nanos = Number(ts.nanos || 0);
  // Fixed-width so history keys sort in anchoring order.
  const sortKey = `${String(seconds).padStart(12, '0')}${String(nanos).padStart(9, '0')}`;
  return { seconds, sortKey };
}

class JusticeLedger extends Contract {
  constructor() {
    super('JusticeLedger');
  }

  /**
   * Anchors a manifest hash, self-authenticated by the capturing device's
   * signature rather than by who submits it.
   * @param manifestHash SHA-256 fingerprint of the evidence manifest (hex).
   * @param cid Pinata/IPFS Content ID of the encrypted clip.
   * @param capturedAt Device-clock capture time (unix seconds). The
   *   gateway's transaction time is also recorded as anchoredAt, so a
   *   wrong or backdated device clock is bounded as far as the gateway is
   *   trusted, not further.
   * @param nodeId The capturing device's 16-hex-character node ID.
   * @param signature 65-byte (r, s, v) EIP-191 signature over the hash (hex).
   */
  async AnchorEvidence(ctx, manifestHash, cid, capturedAt, nodeId, signature) {
    const msp = ctx.clientIdentity.getMSPID();
    if (msp !== ANCHORING_MSP) {
      throw new Error(`Only ${ANCHORING_MSP} may anchor evidence, not ${msp}`);
    }

    const hash = normaliseHex(manifestHash, 64, 'Manifest hash');
    const node = normaliseHex(nodeId, 16, 'Node ID');
    if (String(cid ?? '').trim().length === 0) {
      throw new Error('CID cannot be empty');
    }
    if (!/^\d{1,15}$/.test(String(capturedAt))) {
      throw new Error('capturedAt must be unix seconds');
    }

    const key = ctx.stub.createCompositeKey('evidence', [hash]);
    const existing = await ctx.stub.getState(key);
    if (existing && existing.length > 0) {
      throw new Error('Evidence already stored');
    }

    const signer = recoverSigner(hash, signature);
    const anchoredAt = txTime(ctx);

    // Fixed field order so every peer serialises the record identically.
    const record = {
      manifestHash: hash,
      cid: String(cid),
      capturedAt: Number(capturedAt),
      anchoredAt: anchoredAt.seconds,
      nodeId: node,
      signer,
      txId: ctx.stub.getTxID(),
    };

    await ctx.stub.putState(key, Buffer.from(JSON.stringify(record)));
    await ctx.stub.putState(
      ctx.stub.createCompositeKey('history', [node, anchoredAt.sortKey, hash]),
      Buffer.from(hash),
    );
    ctx.stub.setEvent('EvidenceAnchored', Buffer.from(JSON.stringify(record)));
    return JSON.stringify(record);
  }

  /**
   * Looks up a record by its manifest hash: the starting point a court or
   * guardian actually has (a file), not a victim ID. Unknown hashes return
   * found: false rather than an error, as the app's verifier expects.
   */
  async VerifyEvidence(ctx, manifestHash) {
    const hash = normaliseHex(manifestHash, 64, 'Manifest hash');
    const data = await ctx.stub.getState(ctx.stub.createCompositeKey('evidence', [hash]));
    if (!data || data.length === 0) {
      return JSON.stringify({ found: false, manifestHash: hash });
    }
    return JSON.stringify({ found: true, ...JSON.parse(data.toString('utf8')) });
  }

  /** Every manifest hash anchored under a node ID, in anchoring order. */
  async GetEvidenceHistory(ctx, nodeId) {
    const node = normaliseHex(nodeId, 16, 'Node ID');
    const iterator = await ctx.stub.getStateByPartialCompositeKey('history', [node]);
    const hashes = [];
    try {
      let result = await iterator.next();
      while (!result.done) {
        hashes.push(result.value.value.toString('utf8'));
        result = await iterator.next();
      }
    } finally {
      await iterator.close();
    }
    return JSON.stringify(hashes);
  }

  /**
   * The caller as the chaincode sees it: their org, and the role and flags
   * their CA wrote into the certificate. The authority functions check the
   * same values, so this is how an officer confirms their identity is set
   * up before using them. An attribute the CA registered without the
   * `:ecert` suffix is not in the certificate and shows here as null.
   */
  async WhoAmI(ctx) {
    const identity = ctx.clientIdentity;
    return JSON.stringify({
      mspId: identity.getMSPID(),
      id: identity.getID(),
      role: identity.getAttributeValue('role'),
      unit: identity.getAttributeValue('unit'),
      simulated: identity.getAttributeValue('jc.simulated') === 'true',
    });
  }

  /**
   * Adds an authority (e.g. SimPoliceMSP) that victims can choose as a
   * guardian. [publicKey] is its evidence desk's X25519 key: key pieces
   * are sealed to it, and it is separate from the org's Fabric signing
   * certificates, so a peer admin who can read the ledger still can't open
   * a piece. A simulated authority must say "(SIMULATED)" in its name, so
   * the app can never show it as a real police force.
   */
  async RegisterAuthority(ctx, mspId, name, publicKey, simulated) {
    const registeredBy = requireRegistryAdmin(ctx);
    const id = normaliseMspId(mspId);
    if (REGISTRY_MSPS.includes(id)) {
      throw new Error(`${id} runs the registry and cannot be registered as an authority`);
    }
    const label = String(name ?? '').trim();
    if (label.length === 0 || label.length > 100) {
      throw new Error('name must be 1-100 characters');
    }
    if (simulated !== 'true' && simulated !== 'false') {
      throw new Error('simulated must be "true" or "false"');
    }
    const isSimulated = simulated === 'true';
    if (isSimulated && !label.includes('(SIMULATED)')) {
      throw new Error('A simulated authority\'s name must include "(SIMULATED)"');
    }

    const key = ctx.stub.createCompositeKey('authority', [id]);
    const existing = await ctx.stub.getState(key);
    if (existing && existing.length > 0 && !JSON.parse(existing.toString('utf8')).revoked) {
      throw new Error(`${id} is already registered`);
    }

    // Fixed field order so every peer serialises the record identically.
    const record = {
      mspId: id,
      name: label,
      publicKey: normaliseRawKey(publicKey, 'publicKey'),
      simulated: isSimulated,
      revoked: false,
      registeredAt: txTime(ctx).seconds,
      registeredBy,
    };
    await ctx.stub.putState(key, Buffer.from(JSON.stringify(record)));

    const policy = new KeyEndorsementPolicy();
    policy.addOrgs('PEER', ...REGISTRY_MSPS);
    await ctx.stub.setStateValidationParameter(key, policy.getPolicy());

    ctx.stub.setEvent('AuthorityRegistered', Buffer.from(JSON.stringify(record)));
    return JSON.stringify(record);
  }

  /**
   * Offboards an authority: it stays listed (for the audit trail) but
   * marked revoked, and the authority functions refuse it from then on.
   */
  async RevokeAuthority(ctx, mspId) {
    const revokedBy = requireRegistryAdmin(ctx);
    const id = normaliseMspId(mspId);
    const key = ctx.stub.createCompositeKey('authority', [id]);
    const data = await ctx.stub.getState(key);
    if (!data || data.length === 0) {
      throw new Error(`${id} is not a registered authority`);
    }
    const record = JSON.parse(data.toString('utf8'));
    if (record.revoked) {
      throw new Error(`${id} is already revoked`);
    }
    const updated = { ...record, revoked: true, revokedAt: txTime(ctx).seconds, revokedBy };
    await ctx.stub.putState(key, Buffer.from(JSON.stringify(updated)));
    ctx.stub.setEvent('AuthorityRevoked', Buffer.from(JSON.stringify(updated)));
    return JSON.stringify(updated);
  }

  /** One authority's entry, or found: false. */
  async GetAuthority(ctx, mspId) {
    const id = normaliseMspId(mspId);
    const data = await ctx.stub.getState(ctx.stub.createCompositeKey('authority', [id]));
    if (!data || data.length === 0) {
      return JSON.stringify({ found: false, mspId: id });
    }
    return JSON.stringify({ found: true, ...JSON.parse(data.toString('utf8')) });
  }

  /** Every registered authority, including revoked ones (marked revoked). */
  async ListAuthorities(ctx) {
    const iterator = await ctx.stub.getStateByPartialCompositeKey('authority', []);
    const authorities = [];
    try {
      let result = await iterator.next();
      while (!result.done) {
        authorities.push(JSON.parse(result.value.value.toString('utf8')));
        result = await iterator.next();
      }
    } finally {
      await iterator.close();
    }
    return JSON.stringify(authorities);
  }

  /**
   * A phone registers its node ID and public keys once, so later consents
   * and key releases can be checked against them. Both of the phone's
   * signing keys sign the registration: the Ed25519 key the node ID is
   * derived from (so no one can claim another phone's ID) and the
   * secp256k1 anchoring key (so the address is really the phone's). The
   * first registration of a node ID stands; repeating it is harmless, and
   * different keys for a registered ID are refused (no key rotation yet).
   */
  async RegisterNode(ctx, nodeId, ed25519PublicKey, x25519PublicKey, anchoringAddress, ed25519Signature, anchoringSignature) {
    requireSubmitter(ctx, ANCHORING_MSP, 'register nodes');
    const node = normaliseHex(nodeId, 16, 'Node ID');
    const edKey = normaliseRawKey(ed25519PublicKey, 'ed25519PublicKey');
    const xKey = normaliseRawKey(x25519PublicKey, 'x25519PublicKey');
    const address = normaliseAddress(anchoringAddress);

    if (sha256Hex(Buffer.from(edKey, 'base64')).slice(0, 16) !== node) {
      throw new Error('Node ID does not match the Ed25519 public key');
    }
    const payload = `${ACTION_REGISTER_NODE}|${node}|${edKey}|${xKey}|${address}`;
    if (!verifyEd25519(edKey, payload, ed25519Signature)) {
      throw new Error('Ed25519 signature does not match the registration');
    }
    if (recoverActionSigner(payload, anchoringSignature) !== address) {
      throw new Error('Anchoring signature does not match the anchoring address');
    }

    const key = ctx.stub.createCompositeKey('node', [node]);
    const existing = await readJson(ctx, key);
    if (existing) {
      if (existing.ed25519PublicKey === edKey && existing.x25519PublicKey === xKey &&
          existing.anchoringAddress === address) {
        return JSON.stringify(existing);
      }
      throw new Error(`Node ${node} is already registered with different keys`);
    }

    // Fixed field order so every peer serialises the record identically.
    const record = {
      nodeId: node,
      ed25519PublicKey: edKey,
      x25519PublicKey: xKey,
      anchoringAddress: address,
      registeredAt: txTime(ctx).seconds,
    };
    await ctx.stub.putState(key, Buffer.from(JSON.stringify(record)));
    ctx.stub.setEvent('NodeRegistered', Buffer.from(JSON.stringify(record)));
    return JSON.stringify(record);
  }

  /** A node's registration, or found: false. */
  async GetNode(ctx, nodeId) {
    const node = normaliseHex(nodeId, 16, 'Node ID');
    const record = await readJson(ctx, ctx.stub.createCompositeKey('node', [node]));
    return JSON.stringify(record ? { found: true, ...record } : { found: false, nodeId: node });
  }

  /**
   * The victim's phone records who its guardians are, signed with its
   * anchoring key. Key releases by a guardian are only accepted from nodes
   * on this list. [sequence] must grow with every update, so an old,
   * signed list can't be replayed to bring back a removed guardian.
   * @param guardianNodeIds JSON array of registered node IDs.
   */
  async SetGuardians(ctx, victimNodeId, guardianNodeIds, sequence, anchoringSignature) {
    requireSubmitter(ctx, ANCHORING_MSP, 'set guardians');
    const victim = normaliseHex(victimNodeId, 16, 'Victim node ID');
    const victimRecord = await requireNode(ctx, victim, 'Victim');

    let ids;
    try {
      ids = JSON.parse(guardianNodeIds);
    } catch {
      throw new Error('guardianNodeIds must be a JSON array');
    }
    if (!Array.isArray(ids) || ids.length > MAX_GUARDIANS) {
      throw new Error(`guardianNodeIds must be a JSON array of at most ${MAX_GUARDIANS} node IDs`);
    }
    const guardians = [...new Set(ids.map((id) => normaliseHex(id, 16, 'Guardian node ID')))].sort();
    if (guardians.length !== ids.length) {
      throw new Error('guardianNodeIds contains duplicates');
    }
    if (guardians.includes(victim)) {
      throw new Error('A node cannot be its own guardian');
    }
    for (const guardian of guardians) {
      await requireNode(ctx, guardian, 'Guardian');
    }

    if (!/^\d{1,15}$/.test(String(sequence))) {
      throw new Error('sequence must be a positive integer');
    }
    const seq = Number(sequence);
    const key = ctx.stub.createCompositeKey('guardians', [victim]);
    const previous = await readJson(ctx, key);
    if (seq < 1 || (previous && seq <= previous.sequence)) {
      throw new Error(`sequence must be greater than ${previous ? previous.sequence : 0}`);
    }

    const payload = `${ACTION_SET_GUARDIANS}|${victim}|${seq}|${guardians.join(',')}`;
    if (recoverActionSigner(payload, anchoringSignature) !== victimRecord.anchoringAddress) {
      throw new Error('Signature is not from the victim\'s registered anchoring key');
    }

    const record = { victimNodeId: victim, guardians, sequence: seq, updatedAt: txTime(ctx).seconds };
    await ctx.stub.putState(key, Buffer.from(JSON.stringify(record)));
    ctx.stub.setEvent('GuardiansSet', Buffer.from(JSON.stringify(record)));
    return JSON.stringify(record);
  }

  /** A victim's current guardian list, or found: false. */
  async GetGuardians(ctx, victimNodeId) {
    const victim = normaliseHex(victimNodeId, 16, 'Victim node ID');
    const record = await readJson(ctx, ctx.stub.createCompositeKey('guardians', [victim]));
    return JSON.stringify(record ? { found: true, ...record } : { found: false, victimNodeId: victim });
  }

  /**
   * The victim gives a registered authority one Shamir piece of a clip's
   * key, sealed to the authority's evidence desk key. The sealed piece
   * comes as transient data ("sealedShare", base64), so it never appears in
   * a block: it goes into the authority's private collection, and the
   * channel ledger records only the consent and the piece's hash.
   *
   * The victim's consent is a signature with their registered anchoring
   * key over the clip, the authority, the piece's index and threshold, and
   * the hash of the exact sealed piece, so the gateway can't swap the piece
   * or send it to another authority. The clip must be anchored by the same
   * victim. One piece is still not enough: the threshold stays as recorded.
   */
  async ShareWithAuthority(ctx, manifestHash, authorityMsp, shareX, threshold, anchoringSignature) {
    requireSubmitter(ctx, ANCHORING_MSP, 'share with an authority');
    const hash = normaliseHex(manifestHash, 64, 'Manifest hash');
    const msp = normaliseMspId(authorityMsp);

    const authority = await readJson(ctx, ctx.stub.createCompositeKey('authority', [msp]));
    if (!authority || authority.revoked) {
      throw new Error(`${msp} is not an active registered authority`);
    }
    const collection = AUTHORITY_COLLECTIONS[msp];
    if (!collection) {
      throw new Error(`${msp} has no private collection on this channel`);
    }

    const evidence = await readJson(ctx, ctx.stub.createCompositeKey('evidence', [hash]));
    if (!evidence) {
      throw new Error('Evidence not anchored');
    }
    const victim = await requireNode(ctx, evidence.nodeId, 'Evidence node');
    if (evidence.signer !== victim.anchoringAddress) {
      throw new Error('The evidence was not anchored by its node\'s registered key');
    }

    if (!/^\d{1,3}$/.test(String(shareX)) || Number(shareX) < 1 || Number(shareX) > 255) {
      throw new Error('shareX must be 1-255');
    }
    if (!/^\d$/.test(String(threshold)) || Number(threshold) < 1) {
      throw new Error('threshold must be a small positive integer');
    }
    const x = Number(shareX);
    const t = Number(threshold);

    const transient = ctx.stub.getTransient();
    const sealedText = transient && transient.get('sealedShare')
      ? Buffer.from(transient.get('sealedShare')).toString('utf8') : '';
    const sealed = Buffer.from(sealedText, 'base64');
    if (sealed.length !== SEALED_SHARE_BYTES || sealed.toString('base64') !== sealedText) {
      throw new Error(`Transient sealedShare must be a base64 ${SEALED_SHARE_BYTES}-byte sealed piece`);
    }
    const shareHash = sha256Hex(sealed);

    const payload = `${ACTION_SHARE_WITH_AUTHORITY}|${hash}|${msp}|${x}|${t}|${shareHash}`;
    if (recoverActionSigner(payload, anchoringSignature) !== victim.anchoringAddress) {
      throw new Error('Consent is not signed by the victim\'s registered anchoring key');
    }

    const consentKey = ctx.stub.createCompositeKey('authorityShare', [msp, hash]);
    if (await readJson(ctx, consentKey)) {
      throw new Error(`This clip is already shared with ${msp}`);
    }

    const sharedAt = txTime(ctx).seconds;
    const piece = {
      manifestHash: hash,
      victimNodeId: victim.nodeId,
      authorityMsp: msp,
      shareX: x,
      threshold: t,
      sealedShare: sealedText,
      // The officer portal unseals with the desk key and this key.
      senderX25519PublicKey: victim.x25519PublicKey,
      sharedAt,
    };
    await ctx.stub.putPrivateData(collection, hash, Buffer.from(JSON.stringify(piece)));

    const consent = {
      manifestHash: hash,
      authorityMsp: msp,
      victimNodeId: victim.nodeId,
      shareX: x,
      threshold: t,
      shareHash,
      consentSignature: normaliseHex(anchoringSignature, 130, 'Signature'),
      sharedAt,
      txId: ctx.stub.getTxID(),
    };
    await ctx.stub.putState(consentKey, Buffer.from(JSON.stringify(consent)));
    ctx.stub.setEvent('SharedWithAuthority', Buffer.from(JSON.stringify(consent)));
    return JSON.stringify(consent);
  }

  /** Public consent records for one authority: which clips were shared, never the pieces. */
  async ListAuthorityShares(ctx, authorityMsp) {
    const msp = normaliseMspId(authorityMsp);
    const iterator = await ctx.stub.getStateByPartialCompositeKey('authorityShare', [msp]);
    const consents = [];
    try {
      let result = await iterator.next();
      while (!result.done) {
        consents.push(JSON.parse(result.value.value.toString('utf8')));
        result = await iterator.next();
      }
    } finally {
      await iterator.close();
    }
    return JSON.stringify(consents);
  }

  /**
   * An officer reads their authority's sealed piece for one clip. Only an
   * officer of an active authority may read, and only their own
   * collection; a peer outside the collection (e.g. the Auditor's) has no
   * copy to return. The piece is still sealed to the desk key.
   */
  async GetAuthorityShare(ctx, manifestHash) {
    const msp = ctx.clientIdentity.getMSPID();
    const authority = await readJson(ctx, ctx.stub.createCompositeKey('authority', [msp]));
    if (!authority || authority.revoked || ctx.clientIdentity.getAttributeValue('role') !== 'officer') {
      throw new Error('Only an officer of an active registered authority may read shared pieces');
    }
    const collection = AUTHORITY_COLLECTIONS[msp];
    if (!collection) {
      throw new Error(`${msp} has no private collection on this channel`);
    }
    const hash = normaliseHex(manifestHash, 64, 'Manifest hash');
    const data = await ctx.stub.getPrivateData(collection, hash);
    if (!data || data.length === 0) {
      return JSON.stringify({ found: false, manifestHash: hash });
    }
    return JSON.stringify({ found: true, ...JSON.parse(data.toString('utf8')) });
  }
}

module.exports = JusticeLedger;
