'use strict';

/**
 * HTTP gateway between the Justice-Chain app and the Fabric network.
 * Phones can't talk to Fabric directly (no Dart SDK), so they call this
 * service over Wi-Fi and it submits transactions as JusticeChainOrg
 * (Org1). The victim's device signature travels inside the transaction
 * and is checked by the chaincode, so this gateway can't forge an anchor.
 *
 * Routes:
 *   GET  /health               ledger height, to check the connection
 *   POST /anchor               {manifestHash, cid, capturedAt, nodeId, signature}
 *   GET  /verify/:manifestHash the record, plus the block it committed in
 *   GET  /history/:nodeId      manifest hashes anchored by one node
 *   GET  /authorities          registered authorities (e.g. SimPolice), with
 *                              their evidence-desk X25519 public keys
 *   GET  /authorities/:mspId   one authority, or {found: false}
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

async function anchor(body) {
  const { manifestHash, cid, capturedAt, nodeId, signature } = body;
  const commit = await contract.submitAsync('AnchorEvidence', {
    arguments: [manifestHash, cid, String(capturedAt), nodeId, signature].map((a) => String(a ?? '')),
  });
  const record = JSON.parse(utf8.decode(commit.getResult()));
  const status = await commit.getStatus();
  if (!status.successful) {
    const err = new Error(`Transaction ${status.transactionId} was not committed (code ${status.code})`);
    err.httpStatus = 502;
    throw err;
  }
  return { ...record, blockNumber: Number(status.blockNumber) };
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
