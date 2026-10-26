'use strict';

/**
 * Who is calling the gateway, and what they may read.
 *
 * Phones no longer carry the shared API key (it shipped inside every APK;
 * judge review finding S1/S2). A phone signs each request with the Ed25519
 * key it registered on the ledger:
 *
 *   X-Node-Id    its node ID
 *   X-Timestamp  unix seconds, within MAX_SKEW_SECONDS of the gateway's clock
 *   X-Signature  base64 Ed25519 over
 *                justice-chain/request/v1|METHOD|path|timestamp|sha256(body)
 *
 * The SOS device and the team's own tools keep the API key, which now lives
 * only on the Pi and the laptop. Writes are still checked by the chaincode's
 * own signatures; what this adds is who may read whose records.
 */

const crypto = require('crypto');
const { verifyEd25519 } = require('./mailbox');

const MAX_SKEW_SECONDS = 300;
const NODE_ID = /^[0-9a-f]{16}$/;

function requestPayload(method, path, timestamp, body) {
  const bodyHash = crypto.createHash('sha256').update(body || Buffer.alloc(0)).digest('hex');
  return `justice-chain/request/v1|${method}|${path}|${timestamp}|${bodyHash}`;
}

function forbidden(message) {
  return Object.assign(new Error(message), { httpStatus: 403 });
}

/**
 * @param apiKey   the shared key, or '' for none
 * @param ledger   {getNode(id), getGuardians(id), verify(hash), getAccessRequest(id)}
 * @param now      seconds clock, for tests
 */
function createAuth({ apiKey, ledger, now = () => Math.floor(Date.now() / 1000) }) {
  const keys = new Map(); // node ID -> registered Ed25519 key (registrations never change keys)

  async function edKeyOf(nodeId) {
    if (keys.has(nodeId)) return keys.get(nodeId);
    const node = await ledger.getNode(nodeId);
    if (!node.found) return null;
    keys.set(nodeId, node.ed25519PublicKey);
    return node.ed25519PublicKey;
  }

  function hasApiKey(req) {
    if (!apiKey) return false;
    const given = Buffer.from(String(req.headers['x-api-key'] || ''), 'utf8');
    const expected = Buffer.from(apiKey, 'utf8');
    return given.length === expected.length && crypto.timingSafeEqual(given, expected);
  }

  /** {kind: 'key'}, {kind: 'node', nodeId}, or null when the caller isn't recognised. */
  async function identify(req, pathname, body) {
    if (hasApiKey(req)) return { kind: 'key' };
    const nodeId = String(req.headers['x-node-id'] || '');
    const timestamp = String(req.headers['x-timestamp'] || '');
    const signature = String(req.headers['x-signature'] || '');
    if (!NODE_ID.test(nodeId) || !/^\d{1,15}$/.test(timestamp)) return null;
    if (Math.abs(now() - Number(timestamp)) > MAX_SKEW_SECONDS) return null;
    const edKey = await edKeyOf(nodeId);
    if (!edKey) return null;
    const payload = requestPayload(req.method, pathname, timestamp, body);
    return verifyEd25519(edKey, payload, signature) ? { kind: 'node', nodeId } : null;
  }

  async function isVictimOrGuardian(nodeId, victimNodeId) {
    if (nodeId === victimNodeId) return true;
    const list = await ledger.getGuardians(victimNodeId);
    return Boolean(list.found && list.guardians.includes(nodeId));
  }

  /** The nodes a clip belongs to: whoever anchored it, the record or a claim. */
  async function victimsOf(manifestHash) {
    const found = await ledger.verify(manifestHash);
    if (!found.found) return [];
    return [found, ...(found.claims || [])].map((a) => a.nodeId);
  }

  /**
   * Throws 403 unless [caller] may make this request. The API key may do
   * anything; a phone may read only its own records and those of victims
   * it guards. Everything else a phone sends is a signed write the
   * chaincode checks itself.
   */
  async function authorize(caller, method, parts) {
    if (caller.kind === 'key') return;
    const me = caller.nodeId;
    const [route, arg] = parts;
    if (method !== 'GET') return;
    switch (route) {
      case 'history':
      case 'pieces':
        if (arg !== me) throw forbidden('A phone may only read its own records');
        return;
      case 'guardians':
      case 'access-requests':
        if (!(await isVictimOrGuardian(me, arg))) throw forbidden("Only the victim or her guardians may read this");
        return;
      case 'access-request': {
        const request = await ledger.getAccessRequest(arg);
        if (request.found && !(await isVictimOrGuardian(me, request.victimNodeId))) {
          throw forbidden("Only the victim or her guardians may read this");
        }
        return;
      }
      case 'audit': {
        for (const victim of await victimsOf(arg)) {
          if (await isVictimOrGuardian(me, victim)) return;
        }
        throw forbidden("Only the victim or her guardians may read a clip's audit trail");
      }
      case 'device-setup':
        throw forbidden('Only the device reads its setup package');
      default:
    }
  }

  return { identify, authorize, hasApiKey };
}

/**
 * A fixed-window limit per caller, so one phone (or a leaked key) can't
 * flood the ledger. [limits] maps a bucket name to {max, windowSeconds}.
 */
function createRateLimiter(limits, now = () => Math.floor(Date.now() / 1000)) {
  const windows = new Map();
  return function take(bucket, who) {
    const { max, windowSeconds } = limits[bucket];
    const key = `${bucket}|${who}`;
    const t = now();
    let w = windows.get(key);
    if (!w || t >= w.start + windowSeconds) {
      w = { start: t, count: 0 };
      windows.set(key, w);
    }
    if (++w.count > max) {
      throw Object.assign(new Error('Too many requests; try again later'), { httpStatus: 429 });
    }
  };
}

module.exports = { createAuth, createRateLimiter, requestPayload, MAX_SKEW_SECONDS };
