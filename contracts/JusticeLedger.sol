// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title JusticeLedger
 * @dev Immutable chain-of-custody anchors for encrypted distress evidence.
 *
 * The chain never sees video, keys, or anything identifying a victim by
 * name — only a manifest hash, an IPFS CID, and the capturing device's
 * self-authenticating signature. Anyone (a guardian, or a relayer) can
 * submit a record on a device's behalf without being able to forge one:
 * authorship is tied to whichever address the signature recovers to, not
 * to who paid gas.
 */
contract JusticeLedger {
    struct EvidenceRecord {
        bool found;
        string cid;
        uint64 capturedAt;
        uint64 anchoredAt;
        bytes32 nodeId;
        address signer;
    }

    // manifestHash -> record
    mapping(bytes32 => EvidenceRecord) private records;

    // nodeId -> every manifestHash anchored by that node, in submission order
    mapping(bytes32 => bytes32[]) private history;

    event EvidenceAnchored(
        bytes32 indexed manifestHash,
        string cid,
        uint64 capturedAt,
        bytes32 indexed nodeId,
        address indexed signer
    );

    /**
     * @notice Anchors a manifest hash on-chain, self-authenticated by the
     * capturing device's signature rather than by who submits it.
     * @param manifestHash SHA-256 fingerprint of the evidence manifest.
     * @param cid Pinata/IPFS Content ID of the encrypted clip.
     * @param capturedAt Device-clock capture time (unix seconds). The
     * block's own timestamp is also recorded as anchoredAt, so a wrong or
     * backdated device clock is bounded, not trusted blindly.
     * @param nodeId The capturing device's node ID.
     * @param sig A 65-byte (r, s, v) signature over the EIP-191 "personal
     * sign" prefixed manifestHash, made with the device's anchoring key.
     */
    function storeEvidence(
        bytes32 manifestHash,
        string calldata cid,
        uint64 capturedAt,
        bytes32 nodeId,
        bytes calldata sig
    ) external {
        require(!records[manifestHash].found, "Evidence already stored");
        require(bytes(cid).length > 0, "CID cannot be empty");

        address signer = _recoverSigner(manifestHash, sig);

        records[manifestHash] = EvidenceRecord({
            found: true,
            cid: cid,
            capturedAt: capturedAt,
            anchoredAt: uint64(block.timestamp),
            nodeId: nodeId,
            signer: signer
        });

        history[nodeId].push(manifestHash);

        emit EvidenceAnchored(manifestHash, cid, capturedAt, nodeId, signer);
    }

    /**
     * @notice Looks up a record by its manifest hash — the starting point
     * a court or guardian actually has (a file), not a victim ID.
     */
    function verifyEvidence(bytes32 manifestHash)
        external
        view
        returns (
            bool found,
            string memory cid,
            uint64 capturedAt,
            uint64 anchoredAt,
            bytes32 nodeId,
            address signer
        )
    {
        EvidenceRecord storage record = records[manifestHash];
        return (
            record.found,
            record.cid,
            record.capturedAt,
            record.anchoredAt,
            record.nodeId,
            record.signer
        );
    }

    /**
     * @notice Every manifest hash anchored by a given device, in order.
     */
    function getEvidenceHistory(bytes32 nodeId)
        external
        view
        returns (bytes32[] memory)
    {
        return history[nodeId];
    }

    function _recoverSigner(bytes32 manifestHash, bytes calldata sig)
        private
        pure
        returns (address)
    {
        require(sig.length == 65, "Invalid signature length");

        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(sig.offset)
            s := calldataload(add(sig.offset, 32))
            v := byte(0, calldataload(add(sig.offset, 64)))
        }

        bytes32 ethSignedHash = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", manifestHash)
        );

        return ecrecover(ethSignedHash, v, r, s);
    }
}
