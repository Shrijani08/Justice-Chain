// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract EvidenceRegistry {

    struct Evidence {
        string cid;
        string evidenceHash;
        uint256 timestamp;
        address uploader;
    }

    uint256 private evidenceCount;

    mapping(uint256 => Evidence) public evidenceRecords;

    event EvidenceStored(
        uint256 indexed evidenceId,
        string cid,
        string evidenceHash,
        uint256 timestamp,
        address indexed uploader
    );

    function storeEvidence(
        string memory _cid,
        string memory _evidenceHash
    ) public returns (uint256) {

        evidenceCount++;

        evidenceRecords[evidenceCount] = Evidence(
            _cid,
            _evidenceHash,
            block.timestamp,
            msg.sender
        );

        emit EvidenceStored(
            evidenceCount,
            _cid,
            _evidenceHash,
            block.timestamp,
            msg.sender
        );

        return evidenceCount;
    }

    function getEvidence(
        uint256 _evidenceId
    ) public view returns (
        string memory cid,
        string memory evidenceHash,
        uint256 timestamp,
        address uploader
    ) {
        Evidence memory evidence = evidenceRecords[_evidenceId];

        return (
            evidence.cid,
            evidence.evidenceHash,
            evidence.timestamp,
            evidence.uploader
        );
    }

    function getEvidenceCount() public view returns (uint256) {
        return evidenceCount;
    }
}