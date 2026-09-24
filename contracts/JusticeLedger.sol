// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title JusticeLedger
 * @dev Manages immutable chain-of-custody records for digital distress evidence.
 */
contract JusticeLedger {

    // Structure representing an individual evidence log
    struct Evidence {
        string fileHash;     // SHA-256 Fingerprint
        string ipfsCid;      // IPFS Content Identifier
        uint256 timestamp;   // Blockchain Timestamp
        string guardianId;  // Relay Node ID or "DIRECT"
    }

    // Storage Mapping: Victim ID -> Array of Evidence Records
    mapping(string => Evidence[]) private registry;

    // Event emitted whenever new evidence is successfully logged
    event EvidenceRecorded(
        string indexed victimId,
        string fileHash,
        string ipfsCid,
        uint256 timestamp,
        string guardianId
    );

    /**
     * @notice Seals evidence onto the blockchain.
     * @param _victimId Unique cryptographic identity of the victim.
     * @param _fileHash SHA-256 fingerprint of the recording.
     * @param _ipfsCid Pinata IPFS Content ID.
     * @param _guardianId Secure Node ID if relayed via Mesh, otherwise "DIRECT".
     */
    function recordEvidence(
        string memory _victimId,
        string memory _fileHash,
        string memory _ipfsCid,
        string memory _guardianId
    ) public {
        require(bytes(_victimId).length > 0, "Victim ID cannot be empty");
        require(bytes(_fileHash).length > 0, "File Hash cannot be empty");
        require(bytes(_ipfsCid).length > 0, "IPFS CID cannot be empty");

        Evidence memory newEvidence = Evidence({
            fileHash: _fileHash,
            ipfsCid: _ipfsCid,
            timestamp: block.timestamp,
            guardianId: _guardianId
        });

        registry[_victimId].push(newEvidence);

        emit EvidenceRecorded(
            _victimId,
            _fileHash,
            _ipfsCid,
            block.timestamp,
            _guardianId
        );
    }

    /**
     * @notice Retrieves all evidence records associated with a specific Victim ID.
     * @param _victimId The cryptographic ID to look up.
     * @return Array of Evidence structs associated with the victim.
     */
    function getEvidence(string memory _victimId) public view returns (Evidence[] memory) {
        return registry[_victimId];
    }

    /**
     * @notice Gets total number of evidence logs for a Victim ID.
     * @param _victimId The cryptographic ID to count records for.
     */
    function getEvidenceCount(string memory _victimId) public view returns (uint256) {
        return registry[_victimId].length;
    }
}