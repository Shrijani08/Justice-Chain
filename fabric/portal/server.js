'use strict';

/**
 * SIMULATED officer portal for the "Demo Police Authority (SIMULATED)"
 * (Step 10 of DOCS/08-10-2026 simulated authority guardian on Fabric
 * design.md). It is a demo of how an authority would work with
 * Justice-Chain evidence; no real police system is involved and no real
 * police are contacted.
 *
 * It acts as SimPolice's officer1 (and supervisor1 for the audit trail),
 * on SimPolice's own peer, and holds the evidence desk's X25519 key, which
 * never leaves this machine. It listens on localhost only.
 *
 *   GET  /api/whoami                 officer1 as the ledger sees them
 *   GET  /api/clips                  clips shared with SimPolice, with their
 *                                    ledger record and access requests
 *   POST /api/clips/:hash/requests   {reason, caseRef}: request access
 *   POST /api/clips/:hash/open       unseal the pieces, rebuild the key,
 *                                    fetch the clip from IPFS, decrypt and
 *                                    verify it, record "opened"
 *   GET  /api/videos/:token          the decrypted clip, for 10 minutes
 *   GET  /api/clips/:hash/audit      the clip's audit trail (as supervisor1)
 *
 * IPFS_GATEWAY (default the Pinata gateway, as in the app) is where
 * ciphertext is fetched from: <IPFS_GATEWAY><cid>.
 */

const crypto = require('crypto');
const fs = require('fs');
const http = require('http');
const path = require('path');
const grpc = require('@grpc/grpc-js');
const { connect, signers } = require('@hyperledger/fabric-gateway');
const { common } = require('@hyperledger/fabric-protos');
const { openBox, unsealShare, combineShares } = require('../network/lib/evidence-crypto.cjs');

const ORGS_DIR = process.env.FABRIC_ORGS_DIR ||
  '\\\\wsl.localhost\\Ubuntu\\home\\sara_khurshida\\fabric\\fabric-samples\\test-network\\organizations';
const SIMPOLICE = path.join(ORGS_DIR, 'peerOrganizations', 'simpolice.example.com');
const CONFIG = {
  port: Number(process.env.PORTAL_PORT || 8900),
  channel: process.env.FABRIC_CHANNEL || 'evidence-channel',
  chaincode: process.env.FABRIC_CHAINCODE || 'justiceledger',
  mspId: 'SimPoliceMSP',
  peerEndpoint: process.env.FABRIC_PEER_ENDPOINT || 'localhost:11051',
  peerHostAlias: 'peer0.simpolice.example.com',
  tlsCertPath: path.join(SIMPOLICE, 'peers', 'peer0.simpolice.example.com', 'tls', 'ca.crt'),
  deskKeyPath: path.join(SIMPOLICE, 'evidence-desk', 'x25519_private.pem'),
  ipfsGateway: process.env.IPFS_GATEWAY || 'https://gateway.pinata.cloud/ipfs/',
};
const VIDEO_TTL_MS = 10 * 60 * 1000;
const MAX_BODY_BYTES = 16 * 1024;

const grpcClient = new grpc.Client(
  CONFIG.peerEndpoint,
  grpc.credentials.createSsl(fs.readFileSync(CONFIG.tlsCertPath)),
  { 'grpc.ssl_target_name_override': CONFIG.peerHostAlias },
);

/** The chaincode (and qscc, for block lookups) as one SimPolice user (officer1 or supervisor1). */
function contractsFor(user) {
  const msp = path.join(SIMPOLICE, 'users', `${user}@simpolice.example.com`, 'msp');
  const keyDir = path.join(msp, 'keystore');
  const gateway = connect({
    client: grpcClient,
    identity: { mspId: CONFIG.mspId, credentials: fs.readFileSync(path.join(msp, 'signcerts', 'cert.pem')) },
    signer: signers.newPrivateKeySigner(
      crypto.createPrivateKey(fs.readFileSync(path.join(keyDir, fs.readdirSync(keyDir)[0]))),
    ),
    evaluateOptions: () => ({ deadline: Date.now() + 5000 }),
    endorseOptions: () => ({ deadline: Date.now() + 15000 }),
    submitOptions: () => ({ deadline: Date.now() + 5000 }),
    commitStatusOptions: () => ({ deadline: Date.now() + 60000 }),
  });
  const network = gateway.getNetwork(CONFIG.channel);
  return { contract: network.getContract(CONFIG.chaincode), qscc: network.getContract('qscc') };
}

const { contract: officer, qscc } = contractsFor('officer1');
const { contract: supervisor } = contractsFor('supervisor1');
const deskKey = crypto.createPrivateKey(fs.readFileSync(CONFIG.deskKeyPath));
const utf8 = new TextDecoder();
const videos = new Map();

async function evaluate(contract, name, ...args) {
  return JSON.parse(utf8.decode(await contract.evaluateTransaction(name, ...args.map(String))));
}

async function submit(contract, name, ...args) {
  const commit = await contract.submitAsync(name, { arguments: args.map(String) });
  const result = JSON.parse(utf8.decode(commit.getResult()));
  const status = await commit.getStatus();
  if (!status.successful) {
    throw Object.assign(new Error(`Transaction ${status.transactionId} was not committed (code ${status.code})`),
      { httpStatus: 502 });
  }
  return result;
}

/** The block a record's transaction committed in: the ledger's own evidence of when it was anchored. */
async function blockNumberOf(txId) {
  const bytes = await qscc.evaluateTransaction('GetBlockByTxID', CONFIG.channel, txId);
  return Number(common.Block.deserializeBinary(bytes).getHeader().getNumber());
}

async function verifyEvidence(hash) {
  const record = await evaluate(officer, 'VerifyEvidence', hash);
  if (record.found) record.blockNumber = await blockNumberOf(record.txId);
  return record;
}

function sha256Hex(data) {
  return crypto.createHash('sha256').update(data).digest('hex');
}

function requireHash(value) {
  if (!/^[0-9a-f]{64}$/.test(value)) throw Object.assign(new Error('Bad clip hash'), { httpStatus: 400 });
  return value;
}

async function listClips() {
  const consents = await evaluate(officer, 'ListAuthorityShares', CONFIG.mspId);
  const requestsByVictim = new Map();
  const clips = [];
  for (const consent of consents) {
    if (!requestsByVictim.has(consent.victimNodeId)) {
      requestsByVictim.set(consent.victimNodeId, await evaluate(officer, 'ListAccessRequests', consent.victimNodeId));
    }
    const requests = requestsByVictim.get(consent.victimNodeId)
      .filter((r) => r.manifestHash === consent.manifestHash && r.authorityMsp === CONFIG.mspId);
    const record = await verifyEvidence(consent.manifestHash);
    clips.push({ consent, record, requests });
  }
  return clips.sort((a, b) => b.consent.sharedAt - a.consent.sharedAt);
}

/**
 * Opens a clip end to end and says how each step went. The video is only
 * returned if every check passed; the officer's access is recorded on the
 * ledger before it is.
 */
async function openClip(hash) {
  const checks = [];
  const check = (name, ok, detail) => {
    checks.push({ name, ok, detail });
    if (!ok) throw Object.assign(new Error(`${name}: ${detail}`), { httpStatus: 422, checks });
  };

  const pieces = await evaluate(officer, 'GetAuthorityShare', hash);
  check('Key pieces available', pieces.found, pieces.found ? '' : 'This clip was not shared with SimPolice');
  const all = [pieces, ...pieces.released];
  check('Enough pieces to open', all.length >= pieces.threshold,
    `${all.length} of ${pieces.threshold} pieces held (pieces ${all.map((p) => p.shareX).join(', ')})`);

  let shares;
  try {
    shares = all.map((p) => unsealShare(p.sealedShare, deskKey, p.senderX25519PublicKey));
  } catch {
    check('Pieces unsealed with the evidence desk key', false, 'A piece could not be unsealed');
  }
  check('Pieces unsealed with the evidence desk key', true, `pieces ${shares.map((s) => s.x).join(', ')}`);
  const key = combineShares(shares);

  const record = await verifyEvidence(hash);
  check('Ledger record found', record.found,
    record.found ? `block ${record.blockNumber}, CID ${record.cid}` : 'No anchor for this clip');

  let ciphertext;
  try {
    const response = await fetch(`${CONFIG.ipfsGateway}${record.cid}`, { signal: AbortSignal.timeout(60000) });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    ciphertext = Buffer.from(await response.arrayBuffer());
  } catch (err) {
    check('Encrypted clip downloaded from IPFS', false, err.message);
  }
  check('Encrypted clip downloaded from IPFS', true, `${ciphertext.length} bytes`);

  let clip;
  try {
    clip = openBox(ciphertext, key);
  } catch {
    check('Clip decrypted', false, 'The rebuilt key does not open this file (wrong pieces, or the file was changed)');
  }
  check('Clip decrypted', true, `${clip.length} bytes`);
  check('Hash matches the ledger record', sha256Hex(clip) === hash, 'SHA-256 of the clip equals the anchored hash');

  const node = await evaluate(officer, 'GetNode', record.nodeId);
  check('Recorded by the victim\'s registered phone',
    node.found && node.anchoringAddress === record.signer,
    node.found ? `anchor signed by ${record.signer}` : `node ${record.nodeId} is not registered`);

  await submit(officer, 'RecordAccess', hash, 'opened', 'Opened and verified in the officer portal');
  checks.push({ name: 'Access recorded in the audit trail', ok: true, detail: '"opened" by officer1' });

  const token = crypto.randomBytes(24).toString('hex');
  videos.set(token, clip);
  setTimeout(() => videos.delete(token), VIDEO_TTL_MS).unref();
  return { checks, record, videoUrl: `/api/videos/${token}` };
}

/** Chaincode refusals become 400 with the chaincode's message. */
function toHttpError(err) {
  if (err.httpStatus) return { status: err.httpStatus, message: err.message, checks: err.checks };
  const detail = (err.details || []).map((d) => d.message).find(Boolean) || '';
  const match = /chaincode response \d+, (.*)$/s.exec(detail) || /chaincode response \d+, (.*)$/s.exec(err.message || '');
  if (match) return { status: 400, message: match[1].trim() };
  return { status: 503, message: 'Fabric network unavailable' };
}

function readJson(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > MAX_BODY_BYTES) {
        reject(Object.assign(new Error('Request body too large'), { httpStatus: 413 }));
        req.destroy();
      } else {
        chunks.push(chunk);
      }
    });
    req.on('end', () => {
      try {
        resolve(JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}'));
      } catch {
        reject(Object.assign(new Error('Body must be JSON'), { httpStatus: 400 }));
      }
    });
    req.on('error', reject);
  });
}

function send(res, status, payload) {
  res.writeHead(status, { 'Content-Type': 'application/json', 'X-Simulated-Authority': 'true' });
  res.end(JSON.stringify(payload));
}

const indexHtml = path.join(__dirname, 'public', 'index.html');

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://portal');
  const parts = url.pathname.split('/').filter(Boolean);
  const started = Date.now();
  let status = 200;
  try {
    if (req.method === 'GET' && url.pathname === '/') {
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
      res.end(fs.readFileSync(indexHtml));
    } else if (req.method === 'GET' && url.pathname === '/api/whoami') {
      send(res, 200, await evaluate(officer, 'WhoAmI'));
    } else if (req.method === 'GET' && url.pathname === '/api/clips') {
      send(res, 200, await listClips());
    } else if (req.method === 'POST' && parts[1] === 'clips' && parts[3] === 'requests' && parts.length === 4) {
      const { reason, caseRef } = await readJson(req);
      send(res, 200, await submit(officer, 'RequestAccess', requireHash(parts[2]), reason ?? '', caseRef ?? ''));
    } else if (req.method === 'POST' && parts[1] === 'clips' && parts[3] === 'open' && parts.length === 4) {
      send(res, 200, await openClip(requireHash(parts[2])));
    } else if (req.method === 'GET' && parts[1] === 'clips' && parts[3] === 'audit' && parts.length === 4) {
      send(res, 200, await evaluate(supervisor, 'GetAuditTrail', requireHash(parts[2])));
    } else if (req.method === 'GET' && parts[1] === 'videos' && parts.length === 3 && videos.has(parts[2])) {
      const clip = videos.get(parts[2]);
      res.writeHead(200, { 'Content-Type': 'video/mp4', 'Content-Length': clip.length, 'Cache-Control': 'no-store' });
      res.end(clip);
    } else {
      status = 404;
      send(res, 404, { error: 'Not found' });
    }
  } catch (err) {
    const httpErr = toHttpError(err);
    status = httpErr.status;
    if (status >= 500) console.error(err);
    send(res, status, { error: httpErr.message, checks: httpErr.checks });
  }
  console.log(`${new Date().toISOString()} ${req.method} ${url.pathname} ${status} ${Date.now() - started}ms`);
});

// Localhost only: the portal holds the evidence desk key.
server.listen(CONFIG.port, '127.0.0.1', () => {
  console.log(`SIMULATED officer portal (Demo Police Authority) on http://localhost:${CONFIG.port}`);
  console.log(`Fetching clips from ${CONFIG.ipfsGateway}`);
});
