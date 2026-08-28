const hre = require("hardhat");

async function main() {
  console.log("Deploying EvidenceRegistry...");

  const EvidenceRegistry = await hre.ethers.getContractFactory("EvidenceRegistry");
  const contract = await EvidenceRegistry.deploy();

  await contract.waitForDeployment();

  console.log(
    "EvidenceRegistry deployed to:",
    await contract.getAddress()
  );
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});