/**
 * Step 1: Deploy OmniMarketFeed Origin Contracts on Base Sepolia (84532) and Unichain Sepolia (1301).
 * Optional flag: `--claim-faucet` sends 0.05 Base Sepolia ETH to the official Reactive Faucet
 * (0x2afaFD298b23b62760711756088F75B7409f5967) to mint 5 lREACT on Lasna before Step 2.
 */

import { formatEther, parseAbi, parseEther } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import {
  VERIFIED_OMNI_ADDRESSES,
  baseSepoliaChain,
  createClients,
  getNeuralSignerKey,
  loadFoundryArtifact,
  saveDeployments,
  unichainSepoliaChain,
} from "./lib.js";

const INITIAL_WETH_PRICE_E8 = 3200_00000000n;
const FAUCET_ABI = parseAbi(["function request(address receiver) external payable"]);

async function main() {
  const claimFaucet = process.argv.includes("--claim-faucet");
  const neuralAccount = privateKeyToAccount(getNeuralSignerKey());
  const { abi, bytecode } = loadFoundryArtifact("OmniMarketFeed.sol", "OmniMarketFeed");

  // 1. Deploy primary origin feed on Base Sepolia (84532, 200ms blocks)
  const base = createClients(baseSepoliaChain);
  const baseBalance = await base.publicClient.getBalance({ address: base.account.address });
  console.log(`[Base Sepolia 84532] Deployer: ${base.account.address} | Balance: ${formatEther(baseBalance)} ETH`);
  console.log(`[Neural Signer] Authorized EIP-712 signer: ${neuralAccount.address}`);

  if (claimFaucet) {
    console.log(`[Faucet] Claiming 5 lREACT via Base Sepolia faucet ${VERIFIED_OMNI_ADDRESSES.BASE_SEPOLIA_FAUCET}...`);
    const faucetHash = await base.walletClient.writeContract({
      address: VERIFIED_OMNI_ADDRESSES.BASE_SEPOLIA_FAUCET,
      abi: FAUCET_ABI,
      functionName: "request",
      args: [base.account.address],
      value: parseEther("0.05"),
    });
    await base.publicClient.waitForTransactionReceipt({ hash: faucetHash });
    console.log(`[Faucet] Claim tx confirmed: ${faucetHash}`);
  }

  console.log("[Base Sepolia] Deploying primary OmniMarketFeed...");
  const baseTxHash = await base.walletClient.deployContract({
    abi,
    bytecode,
    args: [base.account.address, neuralAccount.address, INITIAL_WETH_PRICE_E8],
  });
  const baseReceipt = await base.publicClient.waitForTransactionReceipt({ hash: baseTxHash });
  if (!baseReceipt.contractAddress) throw new Error("Base Sepolia OmniMarketFeed deployment failed.");
  console.log(`[Base Sepolia] OmniMarketFeed deployed at ${baseReceipt.contractAddress} (tx: ${baseTxHash})`);

  // 2. Deploy secondary origin feed on Unichain Sepolia (1301, 1s blocks) if wallet has balance
  const unichain = createClients(unichainSepoliaChain);
  const unichainBalance = await unichain.publicClient.getBalance({ address: unichain.account.address });
  console.log(
    `[Unichain Sepolia 1301] Deployer: ${unichain.account.address} | Balance: ${formatEther(unichainBalance)} ETH`
  );

  let unichainMarketFeed = undefined;
  let unichainMarketFeedTx = undefined;
  if (unichainBalance > parseEther("0.002")) {
    console.log("[Unichain Sepolia] Deploying secondary OmniMarketFeed...");
    unichainMarketFeedTx = await unichain.walletClient.deployContract({
      abi,
      bytecode,
      args: [unichain.account.address, neuralAccount.address, INITIAL_WETH_PRICE_E8],
    });
    const uniReceipt = await unichain.publicClient.waitForTransactionReceipt({ hash: unichainMarketFeedTx });
    unichainMarketFeed = uniReceipt.contractAddress ?? undefined;
    console.log(`[Unichain Sepolia] OmniMarketFeed deployed at ${unichainMarketFeed} (tx: ${unichainMarketFeedTx})`);
  } else {
    console.log("[Unichain Sepolia] Skipping secondary feed (fund >= 0.003 Unichain Sepolia ETH to enable spread feed).");
  }

  const saved = saveDeployments({
    deployer: base.account.address,
    neuralSigner: neuralAccount.address,
    baseMarketFeed: baseReceipt.contractAddress,
    baseMarketFeedTx: baseTxHash,
    unichainMarketFeed,
    unichainMarketFeedTx,
  });

  console.log("\n[DONE] Saved origin deployments to deployments/testnet.json:", JSON.stringify(saved, null, 2));
}

main().catch((err) => {
  console.error("[deploy-origin] Failed:", err);
  process.exit(1);
});
