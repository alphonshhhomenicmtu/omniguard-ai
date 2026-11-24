/**
 * Step 3: Deploy Destination OmniGuardVaults on Unichain Sepolia (1301) and Base Sepolia (84532),
 *         fund their CallbackProxy reserves via depositTo(), and register active GuardRules on Reactive Lasna.
 */

import { formatEther, keccak256, parseAbi, parseEther, toHex, type Address } from "viem";
import {
  VERIFIED_OMNI_ADDRESSES,
  baseSepoliaChain,
  createClients,
  loadFoundryArtifact,
  reactiveLasnaChain,
  readDeployments,
  saveDeployments,
  unichainSepoliaChain,
} from "./lib.js";

const PROXY_DEPOSIT_ABI = parseAbi(["function depositTo(address target) external payable"]);
const MARKET_WETH_USDC = keccak256(toHex("WETH/USDC"));
const ZERO_ADDR = "0x0000000000000000000000000000000000000000" as Address;

async function main() {
  const deployments = readDeployments();
  if (!deployments.reactiveGuard) {
    throw new Error("Missing reactiveGuard in deployments/testnet.json. Run 'npm run deploy:reactive' first.");
  }

  const vaultArtifact = loadFoundryArtifact("OmniGuardVault.sol", "OmniGuardVault");
  const reactiveArtifact = loadFoundryArtifact("OmniGuardReactive.sol", "OmniGuardReactive");
  const vaultFund = parseEther(process.env.DESTINATION_VAULT_FUND_ETH || "0.02");
  const proxyDeposit = parseEther(process.env.CALLBACK_PROXY_DEPOSIT_ETH || "0.02");

  // 1. Deploy Base Sepolia Destination Vault
  const base = createClients(baseSepoliaChain);
  console.log(
    `[Base Sepolia] Deploying OmniGuardVault (proxy=${VERIFIED_OMNI_ADDRESSES.BASE_SEPOLIA_CALLBACK_PROXY}, sender=${deployments.reactiveGuard})...`
  );
  const baseVaultTx = await base.walletClient.deployContract({
    abi: vaultArtifact.abi,
    bytecode: vaultArtifact.bytecode,
    args: [VERIFIED_OMNI_ADDRESSES.BASE_SEPOLIA_CALLBACK_PROXY, deployments.reactiveGuard, base.account.address],
    value: vaultFund,
  });
  const baseVaultReceipt = await base.publicClient.waitForTransactionReceipt({ hash: baseVaultTx });
  if (!baseVaultReceipt.contractAddress) throw new Error("Base Sepolia OmniGuardVault deployment failed.");
  const baseVaultAddr = baseVaultReceipt.contractAddress;
  console.log(`[Base Sepolia] OmniGuardVault deployed at ${baseVaultAddr}`);

  const baseDepositTx = await base.walletClient.writeContract({
    address: VERIFIED_OMNI_ADDRESSES.BASE_SEPOLIA_CALLBACK_PROXY,
    abi: PROXY_DEPOSIT_ABI,
    functionName: "depositTo",
    args: [baseVaultAddr],
    value: proxyDeposit,
  });
  await base.publicClient.waitForTransactionReceipt({ hash: baseDepositTx });
  console.log(`[Base Sepolia] Deposited ${formatEther(proxyDeposit)} ETH reserve into CallbackProxy: ${baseDepositTx}`);

  // 2. Deploy Unichain Sepolia Destination Vault (if funded)
  const unichain = createClients(unichainSepoliaChain);
  const uniBal = await unichain.publicClient.getBalance({ address: unichain.account.address });
  let unichainVaultAddr: Address | undefined = undefined;
  let unichainVaultTx = undefined;

  if (uniBal > vaultFund + proxyDeposit) {
    console.log(
      `[Unichain Sepolia] Deploying OmniGuardVault (proxy=${VERIFIED_OMNI_ADDRESSES.UNICHAIN_SEPOLIA_CALLBACK_PROXY}, sender=${deployments.reactiveGuard})...`
    );
    unichainVaultTx = await unichain.walletClient.deployContract({
      abi: vaultArtifact.abi,
      bytecode: vaultArtifact.bytecode,
      args: [
        VERIFIED_OMNI_ADDRESSES.UNICHAIN_SEPOLIA_CALLBACK_PROXY,
        deployments.reactiveGuard,
        unichain.account.address,
      ],
      value: vaultFund,
    });
    const uniVaultReceipt = await unichain.publicClient.waitForTransactionReceipt({ hash: unichainVaultTx });
    unichainVaultAddr = uniVaultReceipt.contractAddress ?? undefined;
    console.log(`[Unichain Sepolia] OmniGuardVault deployed at ${unichainVaultAddr}`);

    if (unichainVaultAddr) {
      const uniDepositTx = await unichain.walletClient.writeContract({
        address: VERIFIED_OMNI_ADDRESSES.UNICHAIN_SEPOLIA_CALLBACK_PROXY,
        abi: PROXY_DEPOSIT_ABI,
        functionName: "depositTo",
        args: [unichainVaultAddr],
        value: proxyDeposit,
      });
      await unichain.publicClient.waitForTransactionReceipt({ hash: uniDepositTx });
      console.log(`[Unichain Sepolia] Deposited ${formatEther(proxyDeposit)} ETH reserve into CallbackProxy: ${uniDepositTx}`);
    }
  } else {
    console.log("[Unichain Sepolia] Insufficient ETH for vault + reserve; routing all default rules to Base Sepolia vault.");
  }

  // 3. Register production GuardRules on OmniGuardReactive (Lasna)
  const lasna = createClients(reactiveLasnaChain);
  const primaryDestChainId = unichainVaultAddr ? BigInt(unichainSepoliaChain.id) : BigInt(baseSepoliaChain.id);
  const primaryDestVault = unichainVaultAddr ?? baseVaultAddr;

  const rulesToRegister = [
    {
      label: "stopLossBaseToDest",
      params: {
        marketId: MARKET_WETH_USDC,
        monitoredVault: ZERO_ADDR,
        destinationChainId: primaryDestChainId,
        destinationVault: primaryDestVault,
        kind: 0, // STOP_LOSS_HEDGE
        actionType: 0, // HEDGE_TO_STABLE
        priceFloorE8: 3050_00000000n,
        maxDrawdownBps: 400,
        minHealthFactorBps: 0,
        aiRiskThresholdBps: 0,
        spreadThresholdBps: 0,
        hedgeBps: 5000,
        cooldownSeconds: 30n,
        expiresAt: 0n,
        callbackGasLimit: 500_000n,
        adaptiveAiEnabled: true,
      },
    },
    {
      label: "healthFactorRescueBase",
      params: {
        marketId: MARKET_WETH_USDC,
        monitoredVault: baseVaultAddr,
        destinationChainId: BigInt(baseSepoliaChain.id),
        destinationVault: baseVaultAddr,
        kind: 1, // HEALTH_FACTOR_RESCUE
        actionType: 1, // DELEVERAGE_COLLATERAL
        priceFloorE8: 0n,
        maxDrawdownBps: 0,
        minHealthFactorBps: 12_500,
        aiRiskThresholdBps: 0,
        spreadThresholdBps: 0,
        hedgeBps: 4000,
        cooldownSeconds: 30n,
        expiresAt: 0n,
        callbackGasLimit: 500_000n,
        adaptiveAiEnabled: true,
      },
    },
    {
      label: "neuralCascadeCircuitBreaker",
      params: {
        marketId: MARKET_WETH_USDC,
        monitoredVault: ZERO_ADDR,
        destinationChainId: primaryDestChainId,
        destinationVault: primaryDestVault,
        kind: 2, // AI_REGIME_ESCALATION
        actionType: 2, // CIRCUIT_BREAKER_PAUSE
        priceFloorE8: 0n,
        maxDrawdownBps: 0,
        minHealthFactorBps: 0,
        aiRiskThresholdBps: 7500,
        spreadThresholdBps: 0,
        hedgeBps: 6000,
        cooldownSeconds: 30n,
        expiresAt: 0n,
        callbackGasLimit: 500_000n,
        adaptiveAiEnabled: true,
      },
    },
  ];

  const ruleIds: Record<string, number> = {};
  let idx = 1;
  for (const r of rulesToRegister) {
    const tx = await lasna.walletClient.writeContract({
      address: deployments.reactiveGuard,
      abi: reactiveArtifact.abi,
      functionName: "createRule",
      args: [r.params],
    });
    await lasna.publicClient.waitForTransactionReceipt({ hash: tx });
    ruleIds[r.label] = idx++;
    console.log(`[Reactive Lasna] Registered rule '${r.label}' (#${ruleIds[r.label]}): ${tx}`);
  }

  const saved = saveDeployments({
    baseGuardVault: baseVaultAddr,
    baseGuardVaultTx: baseVaultTx,
    unichainGuardVault: unichainVaultAddr,
    unichainGuardVaultTx: unichainVaultTx,
    ruleIds,
  });

  console.log("\n[DONE] Full OmniGuard AI testnet topology deployed:", JSON.stringify(saved, null, 2));
}

main().catch((err) => {
  console.error("[deploy-destination] Failed:", err);
  process.exit(1);
});
