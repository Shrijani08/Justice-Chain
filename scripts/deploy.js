import hre from "hardhat";

async function main() {
  console.log("🚀 Deploying JusticeLedger smart contract...");

  // 1. Get the contract factory
  const JusticeLedger = await hre.ethers.getContractFactory("JusticeLedger");

  // 2. Deploy the contract
  const ledger = await JusticeLedger.deploy();

  // 3. Wait for deployment to complete
  await ledger.waitForDeployment();

  const contractAddress = await ledger.getAddress();

  console.log("🎉 JusticeLedger contract deployed successfully!");
  console.log("📍 Deployed Contract Address:", contractAddress);
  console.log("💡 Save this address! You will need it for your Flutter web3 client.");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});