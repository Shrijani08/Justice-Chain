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
 * chaincode records the recovered signer; it does not yet know which
 * signer belongs to which node ID, so verifiers compare the signer with
 * the victim's known anchoring address, as the app does today.
 */

const { Contract } = require('fabric-contract-api');
const { KeyEndorsementPolicy } = require('fabric-shim');
const { getBytes, verifyMessage } = require('ethers');

// Only JusticeChainOrg's gateway submits anchors on behalf of phones.
const ANCHORING_MSP = 'Org1MSP';

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

/** A raw 32-byte X25519 public key in standard base64, as the app stores keys. */
function normaliseX25519PublicKey(value) {
  const text = String(value ?? '').trim();
  const bytes = Buffer.from(text, 'base64');
  if (bytes.length !== 32 || bytes.toString('base64') !== text) {
    throw new Error('publicKey must be a base64 32-byte X25519 key');
  }
  return text;
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
      publicKey: normaliseX25519PublicKey(publicKey),
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
}

module.exports = JusticeLedger;
