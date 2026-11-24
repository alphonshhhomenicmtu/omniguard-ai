/**
 * Step 4: Live End-to-End Testnet Proof & Latency Benchmark Script
 *
 * Executes a real cross-chain protection loop:
 *   1. Emits a -6.00% flash crash on Base Sepolia (OmniMarketFeed.simulateFlashCrash)
 *   2. Signs & submits a live EIP-712 CASCADE_CRITICAL Neural Advisement on Base Sepolia
 *   3. Polls Reactive Lasna (5318007) for ReactionDispatched + SYSTEM.getCallbacks(rvmTxHash)
 *   4. Polls Destination Vault (Unichain Sepolia 1301 or Base Sepolia 84532) for ProtectionExecuted
 *   5. Prints DoraHacks-ready tx hashes + measured end-to-end latency and writes deployments/last-proof.json
 */

import fs from "node:fs";
import path from "node:path";
import { keccak256, parseAbi, parseAbiItem, toHex, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import {
  DEPLOYMENTS_DIR,
  VERIFIED_OMNI_ADDRESSES,
  baseSepoliaChain,
  createClients,
  getNeuralSignerKey,
  loadFoundryArtifact,
  reactiveLasnaChain,
  readDeployments,
  unichainSepoliaChain,
} from "./lib.js";

const MARKET_WETH_USDC = keccak256(toHex("WETH/USDC"));
const SYSTEM_GET_CALLBACKS_ABI = parseAbi([
  "function getCallbacks(uint256 rvmTxHash) external view returns ((uint256 blockNumber, address rvmId, uint256 callbackIx, uint256 destChainId, uint256 destTxHash, bytes err)[])",
]);
const REACTION_EVENT = parseAbiItem(
  "event ReactionDispatched(uint256 indexed ruleId, uint256 indexed destinationChainId, address indexed destinationVault, uint8 kind, uint8 actionType, uint16 effectiveHedgeBps, uint16 aiRiskScoreBps, uint64 originTimestamp, uint64 reactiveTimestamp, uint256 originTxHash)"
);
const PROTECTION_EVENT = parseAbiItem(
  "event ProtectionExecuted(uint256 indexed receiptId, uint256 indexed ruleId, bytes32 indexed marketId, uint8 actionType, uint256 triggerPriceE8, uint16 appliedBps, uint16 aiRiskScoreBps, uint64 originTimestamp, uint64 callbackTimestamp, uint64 endToEndLatencySec, uint256 originTxHash)"
);

async function sleep(ms: number) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function main() {
  const deployments = readDeployments();
  if (!deployments.baseMarketFeed || !deployments.reactiveGuard || !deployments.baseGuardVault) {
    throw new Error("Incomplete deployments/testnet.json. Run 'npm run deploy:all' first.");
  }

  const feedArtifact = loadFoundryArtifact("OmniMarketFeed.sol", "OmniMarketFeed");
  const base = createClients(baseSepoliaChain);
  const lasna = createClients(reactiveLasnaChain);
  const destIsUnichain = Boolean(deployments.unichainGuardVault);
  const dest = createClients(destIsUnichain ? unichainSepoliaChain : baseSepoliaChain);
  const destVaultAddr = (deployments.unichainGuardVault ?? deployments.baseGuardVault) as Address;

  const lasnaStartBlock = await lasna.publicClient.getBlockNumber();
  const destStartBlock = await dest.publicClient.getBlockNumber();

  // 1. Trigger origin flash crash on Base Sepolia
  const wallStartMs = Date.now();
  console.log("[1/4] Triggering -6.00% WETH/USDC flash crash on Base Sepolia...");
  const originTxHash = await base.walletClient.writeContract({
    address: deployments.baseMarketFeed,
    abi: feedArtifact.abi,
    functionName: "simulateFlashCrash",
    args: [MARKET_WETH_USDC, 600, 880n],
  });
  const originReceipt = await base.publicClient.waitForTransactionReceipt({ hash: originTxHash });
  const originConfirmedMs = Date.now();
  console.log(
    `      Origin tx confirmed in ${originConfirmedMs - wallStartMs}ms | block=${originReceipt.blockNumber} | tx=${originTxHash}`
  );

  // 2. Submit EIP-712 Neural Advisement on Base Sepolia (closed-loop AI)
  const neuralAccount = privateKeyToAccount(getNeuralSignerKey());
  const currentNonce = (await base.publicClient.readContract({
    address: deployments.baseMarketFeed,
    abi: feedArtifact.abi,
    functionName: "neuralNonces",
    args: [MARKET_WETH_USDC],
  })) as bigint;
  const nowSec = BigInt(Math.floor(Date.now() / 1000));
  const advisement = {
    marketId: MARKET_WETH_USDC,
    regime: 3, // CASCADE_CRITICAL
    riskScoreBps: 9120,
    recommendedHedgeBps: 6500,
    issuedAt: nowSec,
    validUntil: nowSec + 300n,
    nonce: currentNonce,
  };
  const signature = await neuralAccount.signTypedData({
    domain: {
      name: "OmniGuardMarketFeed",
      version: "1",
      chainId: baseSepoliaChain.id,
      verifyingContract: deployments.baseMarketFeed,
    },
    types: {
      NeuralAdvisement: [
        { name: "marketId", type: "bytes32" },
        { name: "regime", type: "uint8" },
        { name: "riskScoreBps", type: "uint16" },
        { name: "recommendedHedgeBps", type: "uint16" },
        { name: "issuedAt", type: "uint64" },
        { name: "validUntil", type: "uint64" },
        { name: "nonce", type: "uint256" },
      ],
    },
    primaryType: "NeuralAdvisement",
    message: advisement,
  });

  console.log("[2/4] Submitting EIP-712 CASCADE_CRITICAL Neural Advisement on Base Sepolia...");
  const neuralTxHash = await base.walletClient.writeContract({
    address: deployments.baseMarketFeed,
    abi: feedArtifact.abi,
    functionName: "submitSignedNeuralRegime",
    args: [advisement, signature],
  });
  await base.publicClient.waitForTransactionReceipt({ hash: neuralTxHash });
  console.log(`      Neural advisement tx confirmed: ${neuralTxHash}`);

  // 3. Poll Reactive Lasna for ReactionDispatched
  console.log("[3/4] Waiting for Reactive Lasna (Omni ~1s CometBFT) ReactionDispatched event...");
  let reactiveTxHash: Hex | null = null;
  let reactiveDetectedMs = 0;
  for (let attempt = 0; attempt < 30; attempt++) {
    const logs = await lasna.publicClient.getLogs({
      address: deployments.reactiveGuard,
      event: REACTION_EVENT,
      fromBlock: lasnaStartBlock,
      toBlock: "latest",
    });
    if (logs.length > 0) {
      reactiveTxHash = logs[0].transactionHash;
      reactiveDetectedMs = Date.now();
      console.log(`      Reactive tx observed (+${reactiveDetectedMs - originConfirmedMs}ms): ${reactiveTxHash}`);
      break;
    }
    await sleep(1000);
  }

  // 4. Poll Destination Vault for ProtectionExecuted
  console.log(`[4/4] Waiting for Destination OmniGuardVault (${destIsUnichain ? "Unichain" : "Base"} Sepolia) callback...`);
  let callbackTxHash: Hex | null = null;
  let onChainLatencySec: number | null = null;
  let callbackDetectedMs = 0;

  for (let attempt = 0; attempt < 45; attempt++) {
    const logs = await dest.publicClient.getLogs({
      address: destVaultAddr,
      event: PROTECTION_EVENT,
      fromBlock: destStartBlock,
      toBlock: "latest",
    });
    if (logs.length > 0) {
      callbackTxHash = logs[0].transactionHash;
      onChainLatencySec = Number(logs[0].args.endToEndLatencySec ?? 0n);
      callbackDetectedMs = Date.now();
      console.log(
        `      Destination callback confirmed (+${callbackDetectedMs - originConfirmedMs}ms wall, on-chain delta=${onChainLatencySec}s): ${callbackTxHash}`
      );
      break;
    }
    await sleep(1000);
  }

  // Optional validator callback record lookup on Lasna SYSTEM
  let systemCallbackRecords: unknown = [];
  if (reactiveTxHash) {
    try {
      systemCallbackRecords = await lasna.publicClient.readContract({
        address: VERIFIED_OMNI_ADDRESSES.REACTIVE_SYSTEM,
        abi: SYSTEM_GET_CALLBACKS_ABI,
        functionName: "getCallbacks",
        args: [BigInt(reactiveTxHash)],
      });
    } catch {
      systemCallbackRecords = [];
    }
  }

  const proof = {
    recordedAt: new Date().toISOString(),
    originChain: "Base Sepolia (84532)",
    reactiveChain: "Reactive Lasna (5318007)",
    destinationChain: destIsUnichain ? "Unichain Sepolia (1301)" : "Base Sepolia (84532)",
    originTxHash,
    neuralAdvisementTxHash: neuralTxHash,
    reactiveTxHash,
    callbackTxHash,
    onChainEndToEndLatencySec: onChainLatencySec,
    wallClockEndToEndMs: callbackDetectedMs ? callbackDetectedMs - originConfirmedMs : null,
    systemCallbackRecordsCount: Array.isArray(systemCallbackRecords) ? systemCallbackRecords.length : 0,
  };

  fs.mkdirSync(DEPLOYMENTS_DIR, { recursive: true });
  fs.writeFileSync(path.join(DEPLOYMENTS_DIR, "last-proof.json"), JSON.stringify(proof, null, 2) + "\n", "utf8");
  console.log("\n=== DORAHACKS SUBMISSION PROOF ===");
  console.log(JSON.stringify(proof, null, 2));
}

main().catch((err) => {
  console.error("[trigger-demo] Failed:", err);
  process.exit(1);
});
