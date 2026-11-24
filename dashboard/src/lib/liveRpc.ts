import { createPublicClient, formatEther, http, keccak256, parseAbi, toHex, type Address, type Hex } from "viem";
import { DEPLOYED_CONTRACTS, OMNI_NETWORKS } from "./deployments";
import { runNeuralRiskInference } from "./neuralAndCompiler";
import { createInitialLabState, runAdversarialScenario } from "./breakerEngine";

export const MARKET_WETH_USDC = keccak256(toHex("WETH/USDC"));

export const ACTION_TYPE_LABELS = [
  "HEDGE_TO_STABLE",
  "DELEVERAGE_COLLATERAL",
  "CIRCUIT_BREAKER_PAUSE",
  "CROSS_CHAIN_REBALANCE",
] as const;

export const REGIME_LABELS = ["CALM", "ELEVATED", "VOLATILE", "CASCADE_CRITICAL"] as const;

const VAULT_ABI = parseAbi([
  "function owner() external view returns (address)",
  "function getReceiptsCount() external view returns (uint256)",
  "function getReceipt(uint256 index_) external view returns ((uint256 receiptId, uint256 ruleId, uint8 actionType, bytes32 marketId, uint256 triggerPriceE8, uint16 appliedBps, uint16 aiRiskScoreBps, uint64 originTimestamp, uint64 callbackTimestamp, uint64 endToEndLatencySec, uint256 originTxHash, uint256 collateralBeforeUsdE8, uint256 collateralAfterUsdE8, uint256 stableAfterUsdE8, uint256 debtAfterUsdE8))",
  "function getPosition(bytes32 marketId_) external view returns ((uint256 volatileCollateralUsdE8, uint256 stableReserveUsdE8, uint256 debtUsdE8, uint256 rebalancedVolumeUsdE8, bool circuitBreakerActive, uint64 lastActionTimestamp))",
  "function getHealthFactorBps(bytes32 marketId_) external view returns (uint256)",
]);

const REACTIVE_ABI = parseAbi([
  "function owner() external view returns (address)",
  "function nextRuleId() external view returns (uint256)",
  "function totalEventsProcessed() external view returns (uint256)",
  "function totalCallbacksRequested() external view returns (uint256)",
  "function totalNeuralUpdates() external view returns (uint256)",
  "function cronEnabled() external view returns (bool)",
  "function secondaryOriginChainId() external view returns (uint256)",
  "function secondaryOriginFeed() external view returns (address)",
  "function latestNeuralByMarket(bytes32 marketId_) external view returns (uint8 regime, uint16 riskScoreBps, uint16 recommendedHedgeBps, uint64 emittedAt, uint64 validUntil, address signer)",
]);

const FEED_ABI = parseAbi([
  "function owner() external view returns (address)",
  "function neuralSigner() external view returns (address)",
  "function demoModeEnabled() external view returns (bool)",
  "function markets(bytes32 marketId_) external view returns (uint256 lastPriceE8, uint256 lastVolatilityBps, uint64 lastUpdatedAt)",
]);

const PAYABLE_PROXY_ABI = parseAbi([
  "function debt(address contract_) external view returns (uint256)",
]);

export interface OnChainReceiptDecoded {
  receiptId: number;
  ruleId: number;
  actionTypeIndex: number;
  actionType: string;
  marketId: Hex;
  triggerPriceUsd: number;
  appliedBps: number;
  aiRiskScoreBps: number;
  originTimestamp: number;
  callbackTimestamp: number;
  endToEndLatencySec: number;
  originTxHash: Hex;
  collateralBeforeUsd: number;
  collateralAfterUsd: number;
  stableAfterUsd: number;
  debtAfterUsd: number;
}

export interface LiveChainHead {
  name: string;
  chainId: number;
  online: boolean;
  latestBlock: number | null;
  latestTimestamp: number | null;
  rpcLatencyMs: number | null;
  committedFrontier?: { height: number; fromSeq: number; toSeq: number } | null;
  error?: string;
}

export interface LiveOnChainSnapshot {
  fetchedAt: number;
  chains: {
    baseSepolia: LiveChainHead;
    reactiveLasna: LiveChainHead;
    unichainSepolia: LiveChainHead;
  };
  baseFeed: {
    online: boolean;
    owner: Address | null;
    neuralSigner: Address | null;
    demoModeEnabled: boolean | null;
    lastPriceUsd: number | null;
    lastVolatilityBps: number | null;
    lastUpdatedAt: number | null;
  };
  reactive: {
    online: boolean;
    owner: Address | null;
    nextRuleId: number | null;
    totalEventsProcessed: number | null;
    totalCallbacksRequested: number | null;
    totalNeuralUpdates: number | null;
    cronEnabled: boolean | null;
    secondaryOriginChainId: number | null;
    lReactBalance: string | null;
    systemDebt: string | null;
    latestNeuralRegime: string | null;
    latestNeuralRiskBps: number | null;
  };
  unichainVault: {
    online: boolean;
    owner: Address | null;
    receiptsCount: number | null;
    volatileCollateralUsd: number | null;
    stableReserveUsd: number | null;
    debtUsd: number | null;
    rebalancedVolumeUsd: number | null;
    circuitBreakerActive: boolean | null;
    healthFactorBps: number | null;
    ethBalance: string | null;
    proxyDebt: string | null;
    receipts: OnChainReceiptDecoded[];
  };
  baseVault: {
    online: boolean;
    receiptsCount: number | null;
    volatileCollateralUsd: number | null;
    stableReserveUsd: number | null;
    debtUsd: number | null;
    healthFactorBps: number | null;
  };
}

export interface DiagCheckResult {
  id: string;
  label: string;
  status: "PASS" | "WARN" | "FAIL";
  latencyMs: number;
  detail: string;
}

function makeClient(rpcUrl: string) {
  return createPublicClient({
    transport: http(rpcUrl, { timeout: 8_000, retryCount: 1 }),
  });
}

function toHexHash32(val: bigint): Hex {
  return `0x${val.toString(16).padStart(64, "0")}` as Hex;
}

async function rawJsonRpc<T>(rpcUrl: string, method: string, params: unknown[] = []): Promise<T | null> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 7_000);
  try {
    const res = await fetch(rpcUrl, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
      signal: controller.signal,
    });
    if (!res.ok) return null;
    const json = (await res.json()) as { result?: T };
    return json.result ?? null;
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
}

export function decodeRawReceiptTuple(r: {
  receiptId: bigint;
  ruleId: bigint;
  actionType: number;
  marketId: Hex;
  triggerPriceE8: bigint;
  appliedBps: number;
  aiRiskScoreBps: number;
  originTimestamp: bigint;
  callbackTimestamp: bigint;
  endToEndLatencySec: bigint;
  originTxHash: bigint;
  collateralBeforeUsdE8: bigint;
  collateralAfterUsdE8: bigint;
  stableAfterUsdE8: bigint;
  debtAfterUsdE8: bigint;
}): OnChainReceiptDecoded {
  return {
    receiptId: Number(r.receiptId),
    ruleId: Number(r.ruleId),
    actionTypeIndex: Number(r.actionType),
    actionType: ACTION_TYPE_LABELS[Number(r.actionType)] ?? `ACTION_${r.actionType}`,
    marketId: r.marketId,
    triggerPriceUsd: Number(r.triggerPriceE8) / 1e8,
    appliedBps: Number(r.appliedBps),
    aiRiskScoreBps: Number(r.aiRiskScoreBps),
    originTimestamp: Number(r.originTimestamp),
    callbackTimestamp: Number(r.callbackTimestamp),
    endToEndLatencySec: Number(r.endToEndLatencySec),
    originTxHash: toHexHash32(r.originTxHash),
    collateralBeforeUsd: Number(r.collateralBeforeUsdE8) / 1e8,
    collateralAfterUsd: Number(r.collateralAfterUsdE8) / 1e8,
    stableAfterUsd: Number(r.stableAfterUsdE8) / 1e8,
    debtAfterUsd: Number(r.debtAfterUsdE8) / 1e8,
  };
}

export async function fetchLiveOnChainSnapshot(): Promise<LiveOnChainSnapshot> {
  const baseClient = makeClient(OMNI_NETWORKS.baseSepolia.rpcUrl);
  const lasnaClient = makeClient(OMNI_NETWORKS.reactiveLasna.rpcUrl);
  const unichainClient = makeClient(OMNI_NETWORKS.unichainSepolia.rpcUrl);

  const [baseHead, lasnaHead, unichainHead] = await Promise.all([
    (async (): Promise<LiveChainHead> => {
      const t0 = performance.now();
      try {
        const blk = await baseClient.getBlock({ blockTag: "latest" });
        return {
          name: OMNI_NETWORKS.baseSepolia.name,
          chainId: OMNI_NETWORKS.baseSepolia.chainId,
          online: true,
          latestBlock: Number(blk.number),
          latestTimestamp: Number(blk.timestamp),
          rpcLatencyMs: Math.round(performance.now() - t0),
        };
      } catch (err) {
        return {
          name: OMNI_NETWORKS.baseSepolia.name,
          chainId: OMNI_NETWORKS.baseSepolia.chainId,
          online: false,
          latestBlock: null,
          latestTimestamp: null,
          rpcLatencyMs: null,
          error: err instanceof Error ? err.message : "RPC unavailable",
        };
      }
    })(),
    (async (): Promise<LiveChainHead> => {
      const t0 = performance.now();
      try {
        const [blk, frontier] = await Promise.all([
          lasnaClient.getBlock({ blockTag: "latest" }),
          rawJsonRpc<{ height: string; fromSeq: string; toSeq: string }>(
            OMNI_NETWORKS.reactiveLasna.rpcUrl,
            "rnk_getCommittedSequenceFrontier"
          ),
        ]);
        return {
          name: OMNI_NETWORKS.reactiveLasna.name,
          chainId: OMNI_NETWORKS.reactiveLasna.chainId,
          online: true,
          latestBlock: Number(blk.number),
          latestTimestamp: Number(blk.timestamp),
          rpcLatencyMs: Math.round(performance.now() - t0),
          committedFrontier: frontier
            ? {
                height: parseInt(frontier.height, 16),
                fromSeq: parseInt(frontier.fromSeq, 16),
                toSeq: parseInt(frontier.toSeq, 16),
              }
            : null,
        };
      } catch (err) {
        return {
          name: OMNI_NETWORKS.reactiveLasna.name,
          chainId: OMNI_NETWORKS.reactiveLasna.chainId,
          online: false,
          latestBlock: null,
          latestTimestamp: null,
          rpcLatencyMs: null,
          error: err instanceof Error ? err.message : "RPC unavailable",
        };
      }
    })(),
    (async (): Promise<LiveChainHead> => {
      const t0 = performance.now();
      try {
        const blk = await unichainClient.getBlock({ blockTag: "latest" });
        return {
          name: OMNI_NETWORKS.unichainSepolia.name,
          chainId: OMNI_NETWORKS.unichainSepolia.chainId,
          online: true,
          latestBlock: Number(blk.number),
          latestTimestamp: Number(blk.timestamp),
          rpcLatencyMs: Math.round(performance.now() - t0),
        };
      } catch (err) {
        return {
          name: OMNI_NETWORKS.unichainSepolia.name,
          chainId: OMNI_NETWORKS.unichainSepolia.chainId,
          online: false,
          latestBlock: null,
          latestTimestamp: null,
          rpcLatencyMs: null,
          error: err instanceof Error ? err.message : "RPC unavailable",
        };
      }
    })(),
  ]);

  const [baseFeedData, reactiveData, unichainVaultData, baseVaultData] = await Promise.all([
    (async () => {
      try {
        const [owner, neuralSigner, demoModeEnabled, market] = await Promise.all([
          baseClient.readContract({ address: DEPLOYED_CONTRACTS.baseMarketFeed, abi: FEED_ABI, functionName: "owner" }),
          baseClient.readContract({
            address: DEPLOYED_CONTRACTS.baseMarketFeed,
            abi: FEED_ABI,
            functionName: "neuralSigner",
          }),
          baseClient.readContract({
            address: DEPLOYED_CONTRACTS.baseMarketFeed,
            abi: FEED_ABI,
            functionName: "demoModeEnabled",
          }),
          baseClient.readContract({
            address: DEPLOYED_CONTRACTS.baseMarketFeed,
            abi: FEED_ABI,
            functionName: "markets",
            args: [MARKET_WETH_USDC],
          }),
        ]);
        return {
          online: true,
          owner,
          neuralSigner,
          demoModeEnabled,
          lastPriceUsd: Number(market[0]) / 1e8,
          lastVolatilityBps: Number(market[1]),
          lastUpdatedAt: Number(market[2]),
        };
      } catch {
        return {
          online: false,
          owner: null,
          neuralSigner: null,
          demoModeEnabled: null,
          lastPriceUsd: null,
          lastVolatilityBps: null,
          lastUpdatedAt: null,
        };
      }
    })(),
    (async () => {
      try {
        const [
          owner,
          nextRuleId,
          totalEventsProcessed,
          totalCallbacksRequested,
          totalNeuralUpdates,
          cronEnabled,
          secondaryOriginChainId,
          neuralSnap,
          balanceWei,
          debtWei,
        ] = await Promise.all([
          lasnaClient.readContract({
            address: DEPLOYED_CONTRACTS.reactiveGuard,
            abi: REACTIVE_ABI,
            functionName: "owner",
          }),
          lasnaClient.readContract({
            address: DEPLOYED_CONTRACTS.reactiveGuard,
            abi: REACTIVE_ABI,
            functionName: "nextRuleId",
          }),
          lasnaClient.readContract({
            address: DEPLOYED_CONTRACTS.reactiveGuard,
            abi: REACTIVE_ABI,
            functionName: "totalEventsProcessed",
          }),
          lasnaClient.readContract({
            address: DEPLOYED_CONTRACTS.reactiveGuard,
            abi: REACTIVE_ABI,
            functionName: "totalCallbacksRequested",
          }),
          lasnaClient.readContract({
            address: DEPLOYED_CONTRACTS.reactiveGuard,
            abi: REACTIVE_ABI,
            functionName: "totalNeuralUpdates",
          }),
          lasnaClient.readContract({
            address: DEPLOYED_CONTRACTS.reactiveGuard,
            abi: REACTIVE_ABI,
            functionName: "cronEnabled",
          }),
          lasnaClient.readContract({
            address: DEPLOYED_CONTRACTS.reactiveGuard,
            abi: REACTIVE_ABI,
            functionName: "secondaryOriginChainId",
          }),
          lasnaClient.readContract({
            address: DEPLOYED_CONTRACTS.reactiveGuard,
            abi: REACTIVE_ABI,
            functionName: "latestNeuralByMarket",
            args: [MARKET_WETH_USDC],
          }),
          lasnaClient.getBalance({ address: DEPLOYED_CONTRACTS.reactiveGuard }),
          lasnaClient
            .readContract({
              address: OMNI_NETWORKS.reactiveLasna.systemContract,
              abi: PAYABLE_PROXY_ABI,
              functionName: "debt",
              args: [DEPLOYED_CONTRACTS.reactiveGuard],
            })
            .catch(() => 0n),
        ]);

        return {
          online: true,
          owner,
          nextRuleId: Number(nextRuleId),
          totalEventsProcessed: Number(totalEventsProcessed),
          totalCallbacksRequested: Number(totalCallbacksRequested),
          totalNeuralUpdates: Number(totalNeuralUpdates),
          cronEnabled,
          secondaryOriginChainId: Number(secondaryOriginChainId),
          lReactBalance: Number(formatEther(balanceWei)).toFixed(4),
          systemDebt: Number(formatEther(debtWei)).toFixed(5),
          latestNeuralRegime: REGIME_LABELS[Number(neuralSnap[0])] ?? "CALM",
          latestNeuralRiskBps: Number(neuralSnap[1]),
        };
      } catch {
        return {
          online: false,
          owner: null,
          nextRuleId: null,
          totalEventsProcessed: null,
          totalCallbacksRequested: null,
          totalNeuralUpdates: null,
          cronEnabled: null,
          secondaryOriginChainId: null,
          lReactBalance: null,
          systemDebt: null,
          latestNeuralRegime: null,
          latestNeuralRiskBps: null,
        };
      }
    })(),
    (async () => {
      try {
        const [owner, countBig, pos, hfBps, ethWei, debtWei] = await Promise.all([
          unichainClient.readContract({
            address: DEPLOYED_CONTRACTS.unichainGuardVault,
            abi: VAULT_ABI,
            functionName: "owner",
          }),
          unichainClient.readContract({
            address: DEPLOYED_CONTRACTS.unichainGuardVault,
            abi: VAULT_ABI,
            functionName: "getReceiptsCount",
          }),
          unichainClient.readContract({
            address: DEPLOYED_CONTRACTS.unichainGuardVault,
            abi: VAULT_ABI,
            functionName: "getPosition",
            args: [MARKET_WETH_USDC],
          }),
          unichainClient.readContract({
            address: DEPLOYED_CONTRACTS.unichainGuardVault,
            abi: VAULT_ABI,
            functionName: "getHealthFactorBps",
            args: [MARKET_WETH_USDC],
          }),
          unichainClient.getBalance({ address: DEPLOYED_CONTRACTS.unichainGuardVault }),
          unichainClient
            .readContract({
              address: OMNI_NETWORKS.unichainSepolia.callbackProxy,
              abi: PAYABLE_PROXY_ABI,
              functionName: "debt",
              args: [DEPLOYED_CONTRACTS.unichainGuardVault],
            })
            .catch(() => 0n),
        ]);

        const count = Math.min(10, Number(countBig));
        const receipts: OnChainReceiptDecoded[] = [];
        if (count > 0) {
          const rawReceipts = await Promise.all(
            Array.from({ length: count }, (_, idx) =>
              unichainClient.readContract({
                address: DEPLOYED_CONTRACTS.unichainGuardVault,
                abi: VAULT_ABI,
                functionName: "getReceipt",
                args: [BigInt(idx)],
              })
            )
          );
          for (const raw of rawReceipts) {
            receipts.push(decodeRawReceiptTuple(raw));
          }
        }

        return {
          online: true,
          owner,
          receiptsCount: Number(countBig),
          volatileCollateralUsd: Number(pos.volatileCollateralUsdE8) / 1e8,
          stableReserveUsd: Number(pos.stableReserveUsdE8) / 1e8,
          debtUsd: Number(pos.debtUsdE8) / 1e8,
          rebalancedVolumeUsd: Number(pos.rebalancedVolumeUsdE8) / 1e8,
          circuitBreakerActive: pos.circuitBreakerActive,
          healthFactorBps: Number(hfBps),
          ethBalance: Number(formatEther(ethWei)).toFixed(4),
          proxyDebt: Number(formatEther(debtWei)).toFixed(5),
          receipts,
        };
      } catch {
        return {
          online: false,
          owner: null,
          receiptsCount: null,
          volatileCollateralUsd: null,
          stableReserveUsd: null,
          debtUsd: null,
          rebalancedVolumeUsd: null,
          circuitBreakerActive: null,
          healthFactorBps: null,
          ethBalance: null,
          proxyDebt: null,
          receipts: [],
        };
      }
    })(),
    (async () => {
      try {
        const [countBig, pos, hfBps] = await Promise.all([
          baseClient.readContract({
            address: DEPLOYED_CONTRACTS.baseGuardVault,
            abi: VAULT_ABI,
            functionName: "getReceiptsCount",
          }),
          baseClient.readContract({
            address: DEPLOYED_CONTRACTS.baseGuardVault,
            abi: VAULT_ABI,
            functionName: "getPosition",
            args: [MARKET_WETH_USDC],
          }),
          baseClient.readContract({
            address: DEPLOYED_CONTRACTS.baseGuardVault,
            abi: VAULT_ABI,
            functionName: "getHealthFactorBps",
            args: [MARKET_WETH_USDC],
          }),
        ]);
        return {
          online: true,
          receiptsCount: Number(countBig),
          volatileCollateralUsd: Number(pos.volatileCollateralUsdE8) / 1e8,
          stableReserveUsd: Number(pos.stableReserveUsdE8) / 1e8,
          debtUsd: Number(pos.debtUsdE8) / 1e8,
          healthFactorBps: Number(hfBps),
        };
      } catch {
        return {
          online: false,
          receiptsCount: null,
          volatileCollateralUsd: null,
          stableReserveUsd: null,
          debtUsd: null,
          healthFactorBps: null,
        };
      }
    })(),
  ]);

  return {
    fetchedAt: Date.now(),
    chains: {
      baseSepolia: baseHead,
      reactiveLasna: lasnaHead,
      unichainSepolia: unichainHead,
    },
    baseFeed: baseFeedData,
    reactive: reactiveData,
    unichainVault: unichainVaultData,
    baseVault: baseVaultData,
  };
}

export async function runWorkbenchDiagnostics(snapshot?: LiveOnChainSnapshot | null): Promise<DiagCheckResult[]> {
  const results: DiagCheckResult[] = [];
  const tStart = performance.now();
  const snap = snapshot ?? (await fetchLiveOnChainSnapshot());
  const fetchMs = Math.round(performance.now() - tStart);

  results.push({
    id: "rpc-base",
    label: "Base Sepolia (84532) Public RPC & OmniMarketFeed",
    status: snap.chains.baseSepolia.online && snap.baseFeed.online ? "PASS" : "FAIL",
    latencyMs: snap.chains.baseSepolia.rpcLatencyMs ?? fetchMs,
    detail: snap.baseFeed.online
      ? `Block #${snap.chains.baseSepolia.latestBlock?.toLocaleString()} · WETH/USDC $${snap.baseFeed.lastPriceUsd?.toLocaleString()} · demoMode=${String(snap.baseFeed.demoModeEnabled)}`
      : "Unable to query Base Sepolia RPC or feed state",
  });

  results.push({
    id: "rpc-lasna",
    label: "Reactive Lasna (5318007) RPC, Sequence Frontier & OmniGuardReactive",
    status:
      snap.chains.reactiveLasna.online && snap.reactive.online && (snap.reactive.totalCallbacksRequested ?? 0) >= 2
        ? "PASS"
        : snap.chains.reactiveLasna.online
          ? "WARN"
          : "FAIL",
    latencyMs: snap.chains.reactiveLasna.rpcLatencyMs ?? fetchMs,
    detail: snap.reactive.online
      ? `Block #${snap.chains.reactiveLasna.latestBlock?.toLocaleString()} · callbacksRequested=${snap.reactive.totalCallbacksRequested} · balance=${snap.reactive.lReactBalance} lREACT · debt=${snap.reactive.systemDebt}`
      : "Unable to query Reactive Lasna RPC",
  });

  results.push({
    id: "rpc-unichain",
    label: "Unichain Sepolia (1301) RPC & Live getReceipt(0..1) Verification",
    status:
      snap.chains.unichainSepolia.online && snap.unichainVault.online && snap.unichainVault.receipts.length >= 2
        ? "PASS"
        : snap.chains.unichainSepolia.online
          ? "WARN"
          : "FAIL",
    latencyMs: snap.chains.unichainSepolia.rpcLatencyMs ?? fetchMs,
    detail: snap.unichainVault.online
      ? `Block #${snap.chains.unichainSepolia.latestBlock?.toLocaleString()} · receipts=${snap.unichainVault.receiptsCount} · R#0=${snap.unichainVault.receipts[0]?.endToEndLatencySec}s, R#1=${snap.unichainVault.receipts[1]?.endToEndLatencySec}s · debt=${snap.unichainVault.proxyDebt} ETH`
      : "Unable to decode live Unichain receipts",
  });

  // Self-test 4: Client-side OmniRisk-MLP-7x12x4 deterministic inference check
  const tMl = performance.now();
  const calm = runNeuralRiskInference({
    priceChangeBps: -25,
    volatilityBps: 110,
    healthFactorBps: 18_500,
    crossChainSpreadBps: 8,
    recentShocks60s: 0,
    drawdownAccelBps: 0,
    secondsSinceLastTick: 1,
  });
  const critical = runNeuralRiskInference({
    priceChangeBps: -750,
    volatilityBps: 1200,
    healthFactorBps: 11_100,
    crossChainSpreadBps: 240,
    recentShocks60s: 4,
    drawdownAccelBps: 450,
    secondsSinceLastTick: 1,
  });
  const mlPass = calm.regime === "CALM" && critical.regime === "CASCADE_CRITICAL" && critical.riskScoreBps >= 8000;
  results.push({
    id: "self-neural",
    label: "Browser OmniRisk-MLP-7x12x4 Deterministic Forward Pass",
    status: mlPass ? "PASS" : "FAIL",
    latencyMs: Number((performance.now() - tMl).toFixed(2)),
    detail: `CALM=${calm.riskScoreBps} bps (${calm.regime}) vs CASCADE=${critical.riskScoreBps} bps (${critical.regime}, hedge=${critical.recommendedHedgeBps} bps)`,
  });

  // Self-test 5: V2 Adversarial Breaker Guard assertions
  const tGuard = performance.now();
  const baseLab = createInitialLabState();
  const rUnauth = runAdversarialScenario(baseLab, "unauthorized_create_rule");
  const rPaused = runAdversarialScenario(baseLab, "paused_vault_trigger");
  const rReplay = runAdversarialScenario(baseLab, "stale_and_duplicate_replay");
  const rBreaker = runAdversarialScenario(baseLab, "flash_crash_breaker_trip");
  const guardPass =
    rUnauth.result.blocked &&
    rPaused.result.blocked &&
    rReplay.result.blocked &&
    rBreaker.nextState.vault.circuitBreakerActive &&
    rBreaker.result.blocked;
  results.push({
    id: "self-breaker",
    label: "V2 Adversarial Breaker Lab Guard Parity (4 Attack Vectors)",
    status: guardPass ? "PASS" : "FAIL",
    latencyMs: Number((performance.now() - tGuard).toFixed(2)),
    detail: guardPass
      ? "Verified NotAuthorizedRuleCreator, VaultPaused, DuplicateCallbackExecution/StaleSpreadLegSkipped, and CircuitBreakerActive lockouts"
      : "One or more V2 breaker assertions failed",
  });

  return results;
}
