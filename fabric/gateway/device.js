'use strict';

/**
 * The gateway's desk for SOS devices (device/ in the repo). A device has no
 * place on the ledger of its own: its owner's phone vouches for it with an
 * owner certificate, signed by her registered Ed25519 key.
 *
 *  - Setup: the phone leaves a setup package for its device (owner, guardian
 *    list, certificate), sealed so only the device can read it. One slot per
 *    device; the newest package replaces the last.
 *  - Pieces: after anchoring a clip, the device leaves each guardian their
 *    sealed key piece in the same mailbox co-guardians use, so guardians
 *    get device clips without the phone-to-phone mesh. The owner's own
 *    sealed key to the clip goes to her phone the same way, so the clip
 *    shows in her evidence list.
 *
 * The gateway checks everything it can before storing, and the device and
 * the guardians' phones check it all again themselves.
 *
 * Signed texts (Ed25519 over UTF-8), mirrored in device/justice_device/linking.py
 * and lib/core/device_link_service.dart:
 *   justice-chain/device-owner/v1|device|deviceEd25519|deviceX25519|deviceAddress|owner|issuedAt
 *   justice-chain/device-setup/v1|device|owner|issuedAt|sha256(sealed bytes)
 *   justice-chain/device-piece/v1|manifestHash|owner|device|guardian|pieceHash
 */

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { badRequest, pieceHashOf, verifyEd25519 } = require('./mailbox');

const NODE_ID = /^[0-9a-f]{16}$/;

function certificatePayload(c) {
  return [
    'justice-chain/device-owner/v1',
    c.deviceNodeId,
    c.deviceEd25519,
    c.deviceX25519,
    String(c.deviceAnchoringAddress ?? '').toLowerCase(),
    c.ownerNodeId,
    String(c.issuedAt),
  ].join('|');
}

function setupPayload(deviceNodeId, ownerNodeId, issuedAt, sealedB64) {
  const sealedHash = crypto.createHash('sha256').update(Buffer.from(String(sealedB64), 'base64')).digest('hex');
  return `justice-chain/device-setup/v1|${deviceNodeId}|${ownerNodeId}|${issuedAt}|${sealedHash}`;
}

function piecePayload(manifestHash, owner, device, guardian, pieceHash) {
  return `justice-chain/device-piece/v1|${manifestHash}|${owner}|${device}|${guardian}|${pieceHash}`;
}

/** The node ID an Ed25519 key gives: the first 16 hex characters of its SHA-256. */
function nodeIdOf(ed25519B64) {
  return crypto.createHash('sha256').update(Buffer.from(String(ed25519B64), 'base64')).digest('hex').slice(0, 16);
}

function requireNodeId(value, label) {
  if (!NODE_ID.test(String(value))) throw badRequest(`${label} must be 16 hex characters`);
  return String(value);
}

/**
 * @param dir       where setup packages are kept (git-ignored)
 * @param ledger    {getNode(id), getGuardians(id), verifyEvidence(hash)}, read from the chaincode
 * @param mailbox   the guardians' mailbox (mailbox.js)
 */
function createDeviceDesk({ dir, ledger, mailbox }) {
  const setupFile = (deviceNodeId) => path.join(dir, `${requireNodeId(deviceNodeId, 'Device ID')}.json`);

  /** The owner's registration, which must hold the Ed25519 key she signed with. */
  async function owner(ownerNodeId, ed25519) {
    const node = await ledger.getNode(requireNodeId(ownerNodeId, 'Owner ID'));
    if (!node.found) throw badRequest('The owner is not a registered node');
    if (ed25519 !== undefined && node.ed25519PublicKey !== ed25519) {
      throw badRequest("The owner's key is not her registered key");
    }
    return node;
  }

  return {
    async putSetup(deviceNodeId, body) {
      const file = setupFile(deviceNodeId);
      const { ownerNodeId, ownerEd25519, ownerX25519, issuedAt, sealed, signature } = body;
      if (!/^\d{1,15}$/.test(String(issuedAt)) || !sealed || !ownerX25519) {
        throw badRequest('issuedAt, sealed and ownerX25519 are required');
      }
      await owner(ownerNodeId, ownerEd25519);
      if (!verifyEd25519(ownerEd25519, setupPayload(deviceNodeId, ownerNodeId, issuedAt, sealed), signature)) {
        throw badRequest("The setup package is not signed by the owner's registered key");
      }
      const stored = {
        found: true,
        deviceNodeId,
        ownerNodeId,
        ownerEd25519,
        ownerX25519: String(ownerX25519),
        issuedAt: Number(issuedAt),
        sealed: String(sealed),
        signature: String(signature),
      };
      fs.mkdirSync(dir, { recursive: true });
      fs.writeFileSync(file, JSON.stringify(stored));
      return { deviceNodeId, issuedAt: stored.issuedAt };
    },

    getSetup(deviceNodeId) {
      const file = setupFile(deviceNodeId);
      return fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, 'utf8')) : { found: false };
    },

    async putPiece(env) {
      const { manifestHash, victimNodeId, fromNodeId, toNodeId, sealedShare, senderX25519, signature } = env;
      const cert = env.certificate ?? {};
      requireNodeId(fromNodeId, 'Device ID');
      requireNodeId(toNodeId, 'Guardian ID');

      const ownerNode = await owner(victimNodeId);
      if (cert.ownerNodeId !== victimNodeId ||
          !verifyEd25519(ownerNode.ed25519PublicKey, certificatePayload(cert), cert.signature)) {
        throw badRequest("The owner certificate is not signed by the owner's registered key");
      }
      if (cert.deviceNodeId !== fromNodeId || nodeIdOf(cert.deviceEd25519) !== fromNodeId ||
          cert.deviceX25519 !== senderX25519) {
        throw badRequest('The piece does not come from the certified device');
      }
      const pieceHash = pieceHashOf(sealedShare);
      if (!verifyEd25519(cert.deviceEd25519, piecePayload(manifestHash, victimNodeId, fromNodeId, toNodeId, pieceHash), signature)) {
        throw badRequest("The piece is not signed by the device's key");
      }

      // The owner's own key to the clip goes to her phone; pieces go only to
      // her guardians.
      if (toNodeId !== victimNodeId) {
        const list = await ledger.getGuardians(victimNodeId);
        if (!list.found || !list.guardians.includes(toNodeId)) {
          throw badRequest("The recipient is not on the owner's guardian list");
        }
      }
      // The device's own anchor: the record, or a claim if someone else
      // anchored the clip first (chaincode 1.7).
      const found = await ledger.verifyEvidence(manifestHash);
      const deviceAddress = String(cert.deviceAnchoringAddress).toLowerCase();
      const anchor = found.found
        ? [found, ...(found.claims || [])].find((a) => a.nodeId === fromNodeId && a.signer === deviceAddress)
        : null;
      if (!anchor) {
        throw badRequest('The clip is not anchored by this device');
      }

      return mailbox.put({
        kind: 'device',
        manifestHash: anchor.manifestHash,
        victimNodeId,
        fromNodeId,
        toNodeId,
        pieceHash,
        sealedShare,
        senderX25519,
        signature: String(signature),
        certificate: cert,
        share: env.share && typeof env.share === 'object' ? env.share : {},
        forwardedAt: Math.floor(Date.now() / 1000),
        blockNumber: anchor.blockNumber,
      });
    },
  };
}

module.exports = { createDeviceDesk, certificatePayload, setupPayload, piecePayload, nodeIdOf };
