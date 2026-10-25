'use strict';

/**
 * The gateway's mailbox for key pieces one guardian forwards to another
 * (POST /pieces). A piece is sealed to the recipient's X25519 key and
 * signed by the sender, so the gateway can neither read nor alter it; the
 * ledger keeps the piece's hash (ForwardPiece) for the chain of custody.
 * Each recipient has a folder of JSON envelopes. Only the recipient can
 * empty it: an acknowledgement must carry their Ed25519 signature.
 */

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const ACTION_ACK_PIECES = 'justice-chain/ack-pieces/v1';

// DER prefix that turns a raw 32-byte Ed25519 key into an SPKI key.
const ED25519_SPKI_PREFIX = Buffer.from('302a300506032b6570032100', 'hex');

const NODE_ID = /^[0-9a-f]{16}$/;
const ENVELOPE_ID = /^[0-9a-f]{32}$/;

function badRequest(message) {
  return Object.assign(new Error(message), { httpStatus: 400 });
}

function verifyEd25519(publicKeyB64, payload, signatureB64) {
  const signature = Buffer.from(String(signatureB64 ?? ''), 'base64');
  if (signature.length !== 64) return false;
  const key = crypto.createPublicKey({
    key: Buffer.concat([ED25519_SPKI_PREFIX, Buffer.from(String(publicKeyB64), 'base64')]),
    format: 'der',
    type: 'spki',
  });
  return crypto.verify(null, Buffer.from(payload, 'utf8'), key, signature);
}

/** The text a recipient signs to acknowledge (and delete) envelopes. */
function ackPayload(nodeId, ids) {
  return `${ACTION_ACK_PIECES}|${nodeId}|${[...ids].sort().join(',')}`;
}

/** The SHA-256 of a base64 sealed piece, or throws if it isn't base64. */
function pieceHashOf(sealedShare) {
  const bytes = Buffer.from(String(sealedShare ?? ''), 'base64');
  if (bytes.length === 0 || bytes.toString('base64') !== sealedShare) {
    throw badRequest('sealedShare must be base64');
  }
  return crypto.createHash('sha256').update(bytes).digest('hex');
}

function createMailbox(dir) {
  const folder = (nodeId) => {
    if (!NODE_ID.test(String(nodeId))) throw badRequest('Node ID must be 16 hex characters');
    return path.join(dir, nodeId);
  };

  return {
    /**
     * Stores an envelope for its recipient. The ID comes from the clip,
     * both guardians and the piece, so a retry overwrites, never duplicates.
     */
    put(envelope) {
      const id = crypto.createHash('sha256')
        .update(`${envelope.manifestHash}|${envelope.fromNodeId}|${envelope.toNodeId}|${envelope.pieceHash}`)
        .digest('hex').slice(0, 32);
      const target = folder(envelope.toNodeId);
      fs.mkdirSync(target, { recursive: true });
      const stored = { id, ...envelope };
      fs.writeFileSync(path.join(target, `${id}.json`), JSON.stringify(stored));
      return stored;
    },

    /** Every envelope waiting for [nodeId], oldest first. */
    list(nodeId) {
      const target = folder(nodeId);
      if (!fs.existsSync(target)) return [];
      return fs.readdirSync(target)
        .filter((name) => ENVELOPE_ID.test(name.replace(/\.json$/, '')))
        .map((name) => JSON.parse(fs.readFileSync(path.join(target, name), 'utf8')))
        .sort((a, b) => (a.forwardedAt ?? 0) - (b.forwardedAt ?? 0));
    },

    /**
     * Deletes envelopes the recipient has stored. [edPublicKey] is the
     * recipient's registered Ed25519 key, read from the ledger by the caller.
     */
    ack(nodeId, ids, signature, edPublicKey) {
      const target = folder(nodeId);
      if (!Array.isArray(ids) || ids.length === 0 || !ids.every((id) => ENVELOPE_ID.test(String(id)))) {
        throw badRequest('ids must be a non-empty array of envelope IDs');
      }
      if (!edPublicKey || !verifyEd25519(edPublicKey, ackPayload(nodeId, ids), signature)) {
        throw badRequest("Acknowledgement is not signed by the recipient's registered Ed25519 key");
      }
      let deleted = 0;
      for (const id of ids) {
        const file = path.join(target, `${id}.json`);
        if (fs.existsSync(file)) {
          fs.unlinkSync(file);
          deleted++;
        }
      }
      return { deleted };
    },
  };
}

module.exports = { createMailbox, ackPayload, pieceHashOf, verifyEd25519, badRequest };
