'use strict';

/**
 * HTTP gateway between the Justice-Chain app and the Fabric network.
 * Phones can't talk to Fabric directly (no Dart SDK), so they call this
 * service over Wi-Fi and it submits transactions as JusticeChainOrg
 * (Org1). The victim's device signature travels inside the transaction
 * and is checked by the chaincode, so this gateway can't forge an anchor.
 *
 * Every route except /health needs the X-Api-Key header (see API_KEY below).
 *
 * Routes:
 *   GET  /health               ledger height, to check the connection
 *   POST /anchor               {manifestHash, cid, capturedAt, nodeId, signature}
 *   GET  /verify/:manifestHash the record, plus the block it committed in
 *   GET  /history/:nodeId      manifest hashes anchored by one node
 *   GET  /authorities          registered authorities (e.g. SimPolice), with
 *                              their evidence-desk X25519 public keys
 *   GET  /authorities/:mspId   one authority, or {found: false}
 *   POST /nodes                {nodeId, ed25519PublicKey, x25519PublicKey,
 *                              anchoringAddress, ed25519Signature,
 *                              anchoringSignature}: a phone registers itself
 *   GET  /nodes/:nodeId        a registration, or {found: false}
 *   POST /guardians            {victimNodeId, guardianNodeIds, sequence,
 *                              signature}: the victim's signed guardian list
 *   GET  /guardians/:nodeId    a victim's guardian list, or {found: false}
 *   POST /authority-shares     {manifestHash, authorityMsp, shareX, threshold,
 *                              sealedShare, signature}: the victim gives an
 *                              authority one sealed key piece. The piece is
 *                              sent as transient data, so it never appears in
 *                              a block; only the authority's private
 *                              collection holds it.
 *   GET  /authority-shares/:mspId  consents for one authority (no pieces)
 *   GET  /access-requests/:victimNodeId  officers' requests for a victim's clips
 *   GET  /access-request/:requestId      one request, or {found: false}
 *   POST /releases             {requestId, releaserNodeId, shareX, sealedShare,
 *                              signature}: the victim or a guardian approves a
 *                              request by releasing a piece. Two transactions:
 *                              the approval (piece hash only, co-endorsed by
 *                              the Auditor) and then the piece itself, as
 *                              transient data, into the authority's private
 *                              collection. Safe to retry.
 *   GET  /audit/:manifestHash  a clip's chain of custody
 *   POST /pieces               {manifestHash, victimNodeId, fromNodeId, toNodeId,
 *                              sealedShare, senderX25519, signature, share}:
 *                              a guardian sends their key piece to a
 *                              co-guardian. The ledger records the piece's
 *                              hash (ForwardPiece checks both are the victim's
 *                              guardians and the sender's Ed25519 signature);
 *                              the sealed piece waits in the mailbox.
 *   GET  /pieces/:nodeId       envelopes waiting for one guardian
 *   POST /pieces/:nodeId/ack   {ids, signature}: the recipient, signing with
 *                              their registered Ed25519 key, deletes envelopes
 *                              they have stored
 *   POST /device-setup/:deviceNodeId  {ownerNodeId, ownerEd25519, ownerX25519,
 *                              issuedAt, sealed, signature}: a phone leaves its
 *                              SOS device a sealed setup package (device.js)
 *   GET  /device-setup/:deviceNodeId  the latest package, or {found: false}
 *   POST /device-pieces        {manifestHash, victimNodeId, fromNodeId, toNodeId,
 *                              sealedShare, senderX25519, signature, certificate,
 *                              share}: an SOS device leaves a guardian their key
 *                              piece of a clip it anchored; it waits in the
 *                              same mailbox as forwarded pieces
 *
 * Times in records (anchoredAt) are the gateway's clock, not the ledger's;
 * blockNumber is the independent evidence of when a record was committed.
 */

const crypto = require('crypto');
const fs = require('fs');
const http = require('http');
const path = require('path');
const grpc = require('@grpc/grpc-js');
const { connect, signers } = require('@hyperledger/fabric-gateway');
const { common } = require('@hyperledger/fabric-protos');
const { createMailbox, pieceHashOf } = require('./mailbox');
const { createDeviceDesk } = require('./device');

const ORGS_DIR = process.env.FABRIC_ORGS_DIR ||
  '\\\\wsl.localhost\\Ubuntu\\home\\sara_khurshida\\fabric\\fabric-samples\\test-network\\organizations';
const ORG1 = path.join(ORGS_DIR, 'peerOrganizations', 'org1.example.com');
const CONFIG = {
  port: Number(process.env.GATEWAY_PORT || 8800),
  channel: process.env.FABRIC_CHANNEL || 'evidence-channel',
  chaincode: process.env.FABRIC_CHAINCODE || 'justiceledger',
  mspId: 'Org1MSP',
  peerEndpoint: process.env.FABRIC_PEER_ENDPOINT || 'localhost:7051',
  peerHostAlias: 'peer0.org1.example.com',
  certPath: path.join(ORG1, 'users', 'User1@org1.example.com', 'msp', 'signcerts', 'cert.pem'),
  keyDir: path.join(ORG1, 'users', 'User1@org1.example.com', 'msp', 'keystore'),
  tlsCertPath: path.join(ORG1, 'peers', 'peer0.org1.example.com', 'tls', 'ca.crt'),
};
const MAX_BODY_BYTES = 16 * 1024;

// Forwarded key pieces wait here (git-ignored) until their recipient fetches them.
const mailbox = createMailbox(process.env.GATEWAY_MAILBOX_DIR || path.join(__dirname, 'mailbox'));
// SOS devices' setup packages wait here (git-ignored); see device.js.
const deviceDesk = createDeviceDesk({
  dir: process.env.GATEWAY_DEVICE_SETUP_DIR || path.join(__dirname, 'device-setup'),
  ledger: {
    getNode: (id) => evaluate('GetNode', id),
    getGuardians: (id) => evaluate('GetGuardians', id),
    verifyEvidence: (hash) => verify(hash),
  },
  mailbox,
});

// The gateway is reachable from the internet through the ngrok tunnel, so
// every route except /health needs the shared API key in the X-Api-Key
// header. Signatures already stop forged records; the key stops strangers
// from using the gateway at all. The key comes from GATEWAY_API_KEY or the
// git-ignored file api-key.txt next to this script. Without one, the
// gateway refuses to start unless GATEWAY_ALLOW_NO_KEY=1 (local tests only).
const API_KEY_FILE = path.join(__dirname, 'api-key.txt');
const API_KEY = (process.env.GATEWAY_API_KEY ||
  (fs.existsSync(API_KEY_FILE) ? fs.readFileSync(API_KEY_FILE, 'utf8') : '')).trim();
if (!API_KEY && process.env.GATEWAY_ALLOW_NO_KEY !== '1') {
  console.error(`No API key: create ${API_KEY_FILE} (see DOCS, step 8a) or set GATEWAY_API_KEY.`);
  process.exit(1);
}

function hasApiKey(req) {
  if (!API_KEY) return true;
  const given = Buffer.from(String(req.headers['x-api-key'] || ''), 'utf8');
  const expected = Buffer.from(API_KEY, 'utf8');
  return given.length === expected.length && crypto.timingSafeEqual(given, expected);
}

function connectGateway() {
  const client = new grpc.Client(
    CONFIG.peerEndpoint,
    grpc.credentials.createSsl(fs.readFileSync(CONFIG.tlsCertPath)),
    { 'grpc.ssl_target_name_override': CONFIG.peerHostAlias },
  );
  const keyFile = fs.readdirSync(CONFIG.keyDir)[0];
  const gateway = connect({
    client,
    identity: { mspId: CONFIG.mspId, credentials: fs.readFileSync(CONFIG.certPath) },
    signer: signers.newPrivateKeySigner(
      crypto.createPrivateKey(fs.readFileSync(path.join(CONFIG.keyDir, keyFile))),
    ),
    evaluateOptions: () => ({ deadline: Date.now() + 5000 }),
    endorseOptions: () => ({ deadline: Date.now() + 15000 }),
    submitOptions: () => ({ deadline: Date.now() + 5000 }),
    commitStatusOptions: () => ({ deadline: Date.now() + 60000 }),
  });
  const network = gateway.getNetwork(CONFIG.channel);
  return {
    contract: network.getContract(CONFIG.chaincode),
    qscc: network.getContract('qscc'),
  };
}

const { contract, qscc } = connectGateway();
const utf8 = new TextDecoder();

async function ledgerHeight() {
  const bytes = await qscc.evaluateTransaction('GetChainInfo', CONFIG.channel);
  return Number(common.BlockchainInfo.deserializeBinary(bytes).getHeight());
}

async function blockNumberOf(txId) {
  const bytes = await qscc.evaluateTransaction('GetBlockByTxID', CONFIG.channel, txId);
  return Number(common.Block.deserializeBinary(bytes).getHeader().getNumber());
}

/**
 * Submits a transaction and waits for it to commit. The result carries the
 * block it committed in. [transient] values reach the chaincode but are
 * never written to a block.
 */
async function submit(name, args, transient) {
  const options = { arguments: args.map((a) => String(a ?? '')) };
  if (transient) {
    options.transientData = Object.fromEntries(
      Object.entries(transient).map(([key, value]) => [key, Buffer.from(String(value ?? ''), 'utf8')]),
    );
  }
  const commit = await contract.submitAsync(name, options);
  const record = JSON.parse(utf8.decode(commit.getResult()));
  const status = await commit.getStatus();
  if (!status.successful) {
    const err = new Error(`Transaction ${status.transactionId} was not committed (code ${status.code})`);
    err.httpStatus = 502;
    throw err;
  }
  return { ...record, blockNumber: Number(status.blockNumber) };
}

async function evaluate(name, ...args) {
  return JSON.parse(utf8.decode(await contract.evaluateTransaction(name, ...args.map(String))));
}

function anchor(body) {
  const { manifestHash, cid, capturedAt, nodeId, signature } = body;
  return submit('AnchorEvidence', [manifestHash, cid, capturedAt, nodeId, signature]);
}

function registerNode(body) {
  const { nodeId, ed25519PublicKey, x25519PublicKey, anchoringAddress, ed25519Signature, anchoringSignature } = body;
  return submit('RegisterNode',
    [nodeId, ed25519PublicKey, x25519PublicKey, anchoringAddress, ed25519Signature, anchoringSignature]);
}

function setGuardians(body) {
  const { victimNodeId, guardianNodeIds, sequence, signature } = body;
  if (!Array.isArray(guardianNodeIds)) {
    throw Object.assign(new Error('guardianNodeIds must be an array'), { httpStatus: 400 });
  }
  return submit('SetGuardians', [victimNodeId, JSON.stringify(guardianNodeIds), sequence, signature]);
}

/**
 * Approves and delivers a release. A retry after the approval committed but
 * the delivery didn't (a dropped connection, say) skips straight to the
 * delivery, and a delivery that already happened counts as success.
 */
async function releaseShare(body) {
  const { requestId, releaserNodeId, shareX, sealedShare, signature } = body;
  const sealed = Buffer.from(String(sealedShare ?? ''), 'base64');
  if (sealed.length === 0 || sealed.toString('base64') !== sealedShare) {
    throw Object.assign(new Error('sealedShare must be base64'), { httpStatus: 400 });
  }
  const shareHash = crypto.createHash('sha256').update(sealed).digest('hex');

  const current = await evaluate('GetAccessRequest', requestId);
  const alreadyApproved = current.found && current.status === 'released' &&
    current.releasedBy === releaserNodeId && current.releasedShareHash === shareHash;
  const approval = alreadyApproved
    ? current
    : await submit('ReleaseShare', [requestId, releaserNodeId, shareX, shareHash, signature]);

  try {
    const delivery = await submit('DeliverReleasedShare', [requestId], { sealedShare });
    return { ...approval, delivery };
  } catch (err) {
    if (toHttpError(err).message === 'This release was already delivered') return approval;
    throw err;
  }
}

function shareWithAuthority(body) {
  const { manifestHash, authorityMsp, shareX, threshold, sealedShare, signature } = body;
  return submit('ShareWithAuthority', [manifestHash, authorityMsp, shareX, threshold, signature], { sealedShare });
}

/**
 * Records a forwarded piece on the ledger, then leaves it in the
 * recipient's mailbox. Only pieces the ledger accepted are stored.
 */
async function forwardPiece(body) {
  const { manifestHash, victimNodeId, fromNodeId, toNodeId, sealedShare, senderX25519, signature, share } = body;
  const pieceHash = pieceHashOf(sealedShare);
  const record = await submit('ForwardPiece', [manifestHash, victimNodeId, fromNodeId, toNodeId, pieceHash, signature]);
  return mailbox.put({
    manifestHash: record.manifestHash,
    victimNodeId: record.victimNodeId,
    fromNodeId: record.fromNodeId,
    toNodeId: record.toNodeId,
    pieceHash,
    sealedShare,
    senderX25519: String(senderX25519 ?? ''),
    signature: record.signature,
    share: share && typeof share === 'object' ? share : {},
    forwardedAt: record.forwardedAt,
    blockNumber: record.blockNumber,
  });
}

async function ackPieces(nodeId, body) {
  const node = await evaluate('GetNode', nodeId);
  return mailbox.ack(nodeId, body.ids, body.signature, node.found ? node.ed25519PublicKey : null);
}

async function verify(manifestHash) {
  const result = JSON.parse(utf8.decode(await contract.evaluateTransaction('VerifyEvidence', manifestHash)));
  if (result.found) result.blockNumber = await blockNumberOf(result.txId);
  return result;
}

async function history(nodeId) {
  return JSON.parse(utf8.decode(await contract.evaluateTransaction('GetEvidenceHistory', nodeId)));
}

// Read-only: registering an authority needs an Org1 or Org2 admin, which
// this gateway's User1 identity is not (see fabric/network/register-authority.sh).
async function authorities() {
  return JSON.parse(utf8.decode(await contract.evaluateTransaction('ListAuthorities')));
}

async function authority(mspId) {
  return JSON.parse(utf8.decode(await contract.evaluateTransaction('GetAuthority', mspId)));
}

/**
 * Chaincode refusals (bad input, duplicates) become 400 with the
 * chaincode's own message; anything else is a gateway or network problem.
 */
function toHttpError(err) {
  if (err.httpStatus) return { status: err.httpStatus, message: err.message };
  const detail = (err.details || []).map((d) => d.message).find(Boolean) || '';
  const match = /chaincode response \d+, (.*)$/s.exec(detail) || /chaincode response \d+, (.*)$/s.exec(err.message || '');
  if (match) return { status: 400, message: match[1].trim() };
  return { status: 503, message: 'Fabric network unavailable' };
}

function readJson(req) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
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
  res.writeHead(status, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(payload));
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://gateway');
  const parts = url.pathname.split('/').filter(Boolean);
  const started = Date.now();
  let status = 200;
  try {
    if (req.method === 'GET' && url.pathname === '/health') {
      send(res, 200, { ok: true, channel: CONFIG.channel, chaincode: CONFIG.chaincode, height: await ledgerHeight() });
    } else if (!hasApiKey(req)) {
      status = 401;
      send(res, 401, { error: 'Missing or wrong API key' });
    } else if (req.method === 'POST' && url.pathname === '/anchor') {
      send(res, 200, await anchor(await readJson(req)));
    } else if (req.method === 'GET' && parts[0] === 'verify' && parts.length === 2) {
      send(res, 200, await verify(parts[1]));
    } else if (req.method === 'GET' && parts[0] === 'history' && parts.length === 2) {
      send(res, 200, await history(parts[1]));
    } else if (req.method === 'GET' && url.pathname === '/authorities') {
      send(res, 200, await authorities());
    } else if (req.method === 'GET' && parts[0] === 'authorities' && parts.length === 2) {
      send(res, 200, await authority(parts[1]));
    } else if (req.method === 'POST' && url.pathname === '/nodes') {
      send(res, 200, await registerNode(await readJson(req)));
    } else if (req.method === 'GET' && parts[0] === 'nodes' && parts.length === 2) {
      send(res, 200, await evaluate('GetNode', parts[1]));
    } else if (req.method === 'POST' && url.pathname === '/guardians') {
      send(res, 200, await setGuardians(await readJson(req)));
    } else if (req.method === 'GET' && parts[0] === 'guardians' && parts.length === 2) {
      send(res, 200, await evaluate('GetGuardians', parts[1]));
    } else if (req.method === 'POST' && url.pathname === '/authority-shares') {
      send(res, 200, await shareWithAuthority(await readJson(req)));
    } else if (req.method === 'GET' && parts[0] === 'authority-shares' && parts.length === 2) {
      send(res, 200, await evaluate('ListAuthorityShares', parts[1]));
    } else if (req.method === 'GET' && parts[0] === 'access-requests' && parts.length === 2) {
      send(res, 200, await evaluate('ListAccessRequests', parts[1]));
    } else if (req.method === 'GET' && parts[0] === 'access-request' && parts.length === 2) {
      send(res, 200, await evaluate('GetAccessRequest', parts[1]));
    } else if (req.method === 'POST' && url.pathname === '/releases') {
      send(res, 200, await releaseShare(await readJson(req)));
    } else if (req.method === 'GET' && parts[0] === 'audit' && parts.length === 2) {
      send(res, 200, await evaluate('GetAuditTrail', parts[1]));
    } else if (req.method === 'POST' && url.pathname === '/pieces') {
      send(res, 200, await forwardPiece(await readJson(req)));
    } else if (req.method === 'GET' && parts[0] === 'pieces' && parts.length === 2) {
      send(res, 200, mailbox.list(parts[1]));
    } else if (req.method === 'POST' && parts[0] === 'pieces' && parts.length === 3 && parts[2] === 'ack') {
      send(res, 200, await ackPieces(parts[1], await readJson(req)));
    } else if (req.method === 'POST' && parts[0] === 'device-setup' && parts.length === 2) {
      send(res, 200, await deviceDesk.putSetup(parts[1], await readJson(req)));
    } else if (req.method === 'GET' && parts[0] === 'device-setup' && parts.length === 2) {
      send(res, 200, deviceDesk.getSetup(parts[1]));
    } else if (req.method === 'POST' && url.pathname === '/device-pieces') {
      send(res, 200, await deviceDesk.putPiece(await readJson(req)));
    } else {
      status = 404;
      send(res, 404, { error: 'Not found' });
    }
  } catch (err) {
    const httpErr = toHttpError(err);
    status = httpErr.status;
    if (status >= 500) console.error(err);
    send(res, status, { error: httpErr.message });
  }
  console.log(`${new Date().toISOString()} ${req.method} ${url.pathname} ${status} ${Date.now() - started}ms`);
});

server.listen(CONFIG.port, '0.0.0.0', () => {
  console.log(`Justice-Chain Fabric gateway on port ${CONFIG.port} (${CONFIG.channel}/${CONFIG.chaincode})`);
});
