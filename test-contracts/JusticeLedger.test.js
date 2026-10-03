import { expect } from "chai";
import hre from "hardhat";

const { ethers } = hre;

async function signManifestHash(signer, manifestHashBytes32) {
  // Mirrors the Flutter client: a raw EIP-191 "personal sign" over the
  // 32-byte manifest hash, not a string, so it matches what the contract
  // re-derives with ecrecover.
  return signer.signMessage(ethers.getBytes(manifestHashBytes32));
}

describe("JusticeLedger v2", function () {
  async function deployFixture() {
    const [deployer, submitter, nodeSigner, otherSigner] =
      await ethers.getSigners();

    const JusticeLedger = await ethers.getContractFactory("JusticeLedger");
    const ledger = await JusticeLedger.deploy();
    await ledger.waitForDeployment();

    return { ledger, deployer, submitter, nodeSigner, otherSigner };
  }

  function sampleManifest(nodeSigner, suffix = "1") {
    const manifestHash = ethers.keccak256(
      ethers.toUtf8Bytes(`manifest-${suffix}`)
    );
    const nodeId = ethers.encodeBytes32String(`node-${suffix}`.slice(0, 31));
    const cid = `bafy-fake-cid-${suffix}`;
    const capturedAt = Math.floor(Date.now() / 1000);
    return { manifestHash, nodeId, cid, capturedAt };
  }

  it("stores evidence submitted by anyone, self-authenticated by the signature", async function () {
    const { ledger, submitter, nodeSigner } = await deployFixture();
    const { manifestHash, nodeId, cid, capturedAt } =
      sampleManifest(nodeSigner);

    const sig = await signManifestHash(nodeSigner, manifestHash);

    // submitter pays gas; nodeSigner never touches the chain directly.
    await ledger
      .connect(submitter)
      .storeEvidence(manifestHash, cid, capturedAt, nodeId, sig);

    const result = await ledger.verifyEvidence(manifestHash);
    expect(result.found).to.equal(true);
    expect(result.cid).to.equal(cid);
    expect(result.capturedAt).to.equal(BigInt(capturedAt));
    expect(result.nodeId).to.equal(nodeId);
    expect(result.signer).to.equal(nodeSigner.address);
    expect(result.anchoredAt).to.be.greaterThan(0n);
  });

  it("rejects a manifest hash that has already been stored", async function () {
    const { ledger, submitter, nodeSigner } = await deployFixture();
    const { manifestHash, nodeId, cid, capturedAt } =
      sampleManifest(nodeSigner);
    const sig = await signManifestHash(nodeSigner, manifestHash);

    await ledger
      .connect(submitter)
      .storeEvidence(manifestHash, cid, capturedAt, nodeId, sig);

    await expect(
      ledger
        .connect(submitter)
        .storeEvidence(manifestHash, cid, capturedAt, nodeId, sig)
    ).to.be.revertedWith("Evidence already stored");
  });

  it("verifyEvidence on an unknown hash returns found = false", async function () {
    const { ledger } = await deployFixture();

    const result = await ledger.verifyEvidence(
      ethers.keccak256(ethers.toUtf8Bytes("never-anchored"))
    );

    expect(result.found).to.equal(false);
  });

  it("getEvidenceHistory returns every hash anchored by one node, in order", async function () {
    const { ledger, submitter, nodeSigner } = await deployFixture();
    const first = sampleManifest(nodeSigner, "a");
    const second = sampleManifest(nodeSigner, "b");
    const sameNodeId = first.nodeId;

    const sigFirst = await signManifestHash(nodeSigner, first.manifestHash);
    const sigSecond = await signManifestHash(nodeSigner, second.manifestHash);

    await ledger
      .connect(submitter)
      .storeEvidence(
        first.manifestHash,
        first.cid,
        first.capturedAt,
        sameNodeId,
        sigFirst
      );
    await ledger
      .connect(submitter)
      .storeEvidence(
        second.manifestHash,
        second.cid,
        second.capturedAt,
        sameNodeId,
        sigSecond
      );

    const history = await ledger.getEvidenceHistory(sameNodeId);
    expect(history).to.deep.equal([first.manifestHash, second.manifestHash]);
  });

  it("recovers a different signer address for a signature from a different key", async function () {
    const { ledger, submitter, nodeSigner, otherSigner } =
      await deployFixture();
    const { manifestHash, nodeId, cid, capturedAt } =
      sampleManifest(nodeSigner);

    // Signed by a different key than the one named in the call — the
    // contract doesn't know or care who "should" have signed; it just
    // records whoever actually did.
    const sig = await signManifestHash(otherSigner, manifestHash);

    await ledger
      .connect(submitter)
      .storeEvidence(manifestHash, cid, capturedAt, nodeId, sig);

    const result = await ledger.verifyEvidence(manifestHash);
    expect(result.signer).to.equal(otherSigner.address);
    expect(result.signer).to.not.equal(nodeSigner.address);
  });
});
