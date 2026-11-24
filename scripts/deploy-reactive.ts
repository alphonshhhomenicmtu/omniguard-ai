/**
 * Step 2: Deploy OmniGuardReactive on Reactive Lasna Testnet (Chain ID 5318007)
 *         against Reactive Omni SYSTEM (0x8888888888888888888888888888888888888888).
 *
 * Follows Reactive Omni's mandatory deployment sequence:
 *   Origin Feed(s) -> OmniGuardReactive (funded in lREACT) -> Destination OmniGuardVault(s) -> Rule registration.
 */

import { formatEther, parseEther } from "viem";
import {
  baseSepoliaChain,
  createClients,
  loadFoundryArtifact,
  reactiveLasnaChain,
  readDeployments,
  saveDeployments,
  unichainSepoliaChain,
} from "./lib.js";

async function main() {
  const deployments = readDeployments();
  if (!deployments.baseMarketFeed) {
    throw new Error("Missing baseMarketFeed in deployments/testnet.json. Run 'npm run deploy:origin' first.");
  }

  const { abi, bytecode } = loadFoundryArtifact("OmniGuardReactive.sol", "OmniGuardReactive");
  const lasna = createClients(reactiveLasnaChain);
  const balance = await lasna.publicClient.getBalance({ address: lasna.account.address });
  const fundValue = parseEther(process.env.REACTIVE_CONTRACT_FUND_ETH || "0.25");

  console.log(`[Reactive Lasna 5318007] Deployer: ${lasna.account.address} | Balance: ${formatEther(balance)} lREACT`);
  console.log(`[Reactive Lasna] Deploying OmniGuardReactive (funding with ${formatEther(fundValue)} lREACT)...`);

  const txHash = await lasna.walletClient.deployContract({
    abi,
    bytecode,
    args: [BigInt(baseSepoliaChain.id), deployments.baseMarketFeed, lasna.account.address],
    value: fundValue,
  });

  const receipt = await lasna.publicClient.waitForTransactionReceipt({ hash: txHash });
  if (!receipt.contractAddress) throw new Error("OmniGuardReactive deployment failed.");
  const reactiveAddr = receipt.contractAddress;
  console.log(`[Reactive Lasna] OmniGuardReactive deployed at ${reactiveAddr} (tx: ${txHash})`);

  // Subscribe secondary Unichain Sepolia feed if deployed
  if (deployments.unichainMarketFeed) {
    console.log(`[Reactive Lasna] Subscribing secondary feed on Unichain Sepolia (${deployments.unichainMarketFeed})...`);
    const subTx = await lasna.walletClient.writeContract({
      address: reactiveAddr,
      abi,
      functionName: "setSecondaryOriginFeed",
      args: [BigInt(unichainSepoliaChain.id), deployments.unichainMarketFeed],
    });
    await lasna.publicClient.waitForTransactionReceipt({ hash: subTx });
    console.log(`[Reactive Lasna] Secondary feed subscription confirmed: ${subTx}`);
  }

  // Verify subscription registration via Reactive custom JSON-RPC rnk_getFilters
  try {
    const rpcUrl = process.env.REACTIVE_RPC_URL || "https://lasna-rpc.rnk.dev/";
    const res = await fetch(rpcUrl, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", method: "rnk_getFilters", params: [], id: 1 }),
    });
    const json = (await res.json()) as {
      result?: {
        version?: number;
        topicFilters?: Array<{ Configs?: Array<{ Contract?: string; Active?: boolean }> }>;
      };
    };
    const matches = (json.result?.topicFilters || []).filter((f) =>
      f.Configs?.some((c) => c.Contract?.toLowerCase() === reactiveAddr.toLowerCase())
    );
    console.log(`[Reactive Lasna] rnk_getFilters check: version=${json.result?.version}, active filters for OmniGuardReactive=${matches.length}`);
  } catch (err) {
    console.warn("[Reactive Lasna] Optional rnk_getFilters verification skipped:", err);
  }

  const saved = saveDeployments({
    reactiveGuard: reactiveAddr,
    reactiveGuardTx: txHash,
  });

  console.log("\n[DONE] Saved reactive deployment to deployments/testnet.json:", JSON.stringify(saved, null, 2));
}

main().catch((err) => {
  console.error("[deploy-reactive] Failed:", err);
  process.exit(1);
});
