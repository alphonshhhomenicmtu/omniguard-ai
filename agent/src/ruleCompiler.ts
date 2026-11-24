/**
 * OmniGuard AI — Natural-Language Guard Rule Compiler
 *
 * Compiles plain-English automation intents ("Set It and Forget It") into exact
 * OmniGuardReactive.CreateRuleParams structs + ABI-encoded calldata ready for Reactive Lasna.
 * Enforces strict Unix timestamp cooldowns (automatically converting any block-based mention
 * into Base Sepolia timestamp seconds with an explicit safety advisory).
 */

import { encodeFunctionData, keccak256, parseAbi, toHex, type Address, type Hex } from "viem";

export type RuleKindName =
  | "STOP_LOSS_HEDGE"
  | "HEALTH_FACTOR_RESCUE"
  | "AI_REGIME_ESCALATION"
  | "CROSS_CHAIN_REBALANCE";

export type ActionTypeName =
  | "HEDGE_TO_STABLE"
  | "DELEVERAGE_COLLATERAL"
  | "CIRCUIT_BREAKER_PAUSE"
  | "CROSS_CHAIN_REBALANCE";

export interface CompiledRule {
  title: string;
  naturalLanguage: string;
  compilerEngine: "openai-llm" | "deterministic-nlp";
  marketSymbol: "WETH/USDC" | "WBTC/USDC";
  marketId: Hex;
  destinationChainId: number;
  destinationChainName: "Unichain Sepolia" | "Base Sepolia";
  destinationVault: Address;
  kindIndex: 0 | 1 | 2 | 3;
  kind: RuleKindName;
  actionTypeIndex: 0 | 1 | 2 | 3;
  actionType: ActionTypeName;
  priceFloorUsd: number;
  priceFloorE8: string;
  maxDrawdownBps: number;
  minHealthFactorBps: number;
  aiRiskThresholdBps: number;
  spreadThresholdBps: number;
  hedgeBps: number;
  cooldownSeconds: number;
  expiresAt: number;
  callbackGasLimit: number;
  adaptiveAiEnabled: boolean;
  warnings: string[];
  rationale: string;
  encodedCalldata: Hex;
}

const CREATE_RULE_ABI = parseAbi([
  "function createRule((bytes32 marketId, address monitoredVault, uint256 destinationChainId, address destinationVault, uint8 kind, uint8 actionType, uint256 priceFloorE8, uint16 maxDrawdownBps, uint16 minHealthFactorBps, uint16 aiRiskThresholdBps, uint16 spreadThresholdBps, uint16 hedgeBps, uint64 cooldownSeconds, uint64 expiresAt, uint64 callbackGasLimit, bool adaptiveAiEnabled) params_) external returns (uint256)",
]);

const DEFAULT_UNICHAIN_VAULT = "0x1111111111111111111111111111111111111301" as Address;
const DEFAULT_BASE_VAULT = "0x1111111111111111111111111111111111184532" as Address;

export interface CompileOptions {
  baseVaultAddress?: Address;
  unichainVaultAddress?: Address;
}

export function marketIdFromSymbol(symbol: "WETH/USDC" | "WBTC/USDC"): Hex {
  return keccak256(toHex(symbol));
}

function parsePercentAfterKeywords(text: string, regex: RegExp): number | null {
  const m = text.match(regex);
  if (!m) return null;
  const val = parseFloat(m[1]);
  return Number.isFinite(val) ? Math.round(val * 100) : null;
}

export async function compileNaturalLanguageRule(
  prompt: string,
  options: CompileOptions = {}
): Promise<CompiledRule> {
  const cleanPrompt = prompt.trim();
  const lower = cleanPrompt.toLowerCase();
  const warnings: string[] = [];

  // Detect market pair
  const marketSymbol: "WETH/USDC" | "WBTC/USDC" =
    /\b(wbtc|btc|bitcoin)\b/i.test(lower) ? "WBTC/USDC" : "WETH/USDC";
  const marketId = marketIdFromSymbol(marketSymbol);

  // Detect destination chain
  const targetsBase =
    /\b(on base|to base|my base vault|base sepolia vault|base vault)\b/i.test(lower) &&
    !/\b(to unichain|on unichain)\b/i.test(lower);
  const destinationChainId = targetsBase ? 84532 : 1301;
  const destinationChainName: "Unichain Sepolia" | "Base Sepolia" = targetsBase
    ? "Base Sepolia"
    : "Unichain Sepolia";
  const destinationVault = targetsBase
    ? options.baseVaultAddress ?? DEFAULT_BASE_VAULT
    : options.unichainVaultAddress ?? DEFAULT_UNICHAIN_VAULT;

  // Detect rule kind & action type
  let kind: RuleKindName = "STOP_LOSS_HEDGE";
  let kindIndex: 0 | 1 | 2 | 3 = 0;
  let actionType: ActionTypeName = "HEDGE_TO_STABLE";
  let actionTypeIndex: 0 | 1 | 2 | 3 = 0;

  if (/\b(health\s*factor|hf|liquidat|deleverage|repay\s*debt)\b/i.test(lower)) {
    kind = "HEALTH_FACTOR_RESCUE";
    kindIndex = 1;
    actionType = "DELEVERAGE_COLLATERAL";
    actionTypeIndex = 1;
  } else if (/\b(spread|arbitrage|cross[- ]?chain\s*rebalance|price\s*gap|divergence|base\s*vs\.?\s*unichain|unichain\s*vs\.?\s*base)\b/i.test(lower)) {
    kind = "CROSS_CHAIN_REBALANCE";
    kindIndex = 3;
    actionType = "CROSS_CHAIN_REBALANCE";
    actionTypeIndex = 3;
  } else if (/\b(neural|ai\s*risk|cascade|circuit\s*breaker|regime)\b/i.test(lower) && !/\bdrop|fall|below\s*\$/i.test(lower)) {
    kind = "AI_REGIME_ESCALATION";
    kindIndex = 2;
    actionType = "CIRCUIT_BREAKER_PAUSE";
    actionTypeIndex = 2;
  }

  if (/\b(circuit\s*breaker|emergency\s*pause|freeze)\b/i.test(lower)) {
    actionType = "CIRCUIT_BREAKER_PAUSE";
    actionTypeIndex = 2;
  } else if (/\b(deleverage|repay\s*debt)\b/i.test(lower)) {
    actionType = "DELEVERAGE_COLLATERAL";
    actionTypeIndex = 1;
  }

  // Parse numeric thresholds
  const floorMatch = cleanPrompt.match(/(?:below|under|floor|<)\s*\$?\s*([0-9][0-9,]*(?:\.[0-9]+)?)/i);
  let priceFloorUsd = 0;
  if (floorMatch && kind === "STOP_LOSS_HEDGE") {
    const parsed = parseFloat(floorMatch[1].replace(/,/g, ""));
    if (Number.isFinite(parsed) && parsed > 50) {
      priceFloorUsd = parsed;
    }
  }

  const dropBps =
    parsePercentAfterKeywords(lower, /(?:drop|drops|fall|falls|crash|drawdown|down)[^\d%]{0,20}(\d+(?:\.\d+)?)\s*%/i) ??
    (kind === "STOP_LOSS_HEDGE" ? 400 : 0);

  const hfMatch = lower.match(/(?:health\s*factor|hf)[^\d]{0,20}(\d+(?:\.\d+)?)x?/i);
  const minHealthFactorBps =
    kind === "HEALTH_FACTOR_RESCUE"
      ? hfMatch
        ? Math.round(parseFloat(hfMatch[1]) * 10_000)
        : 12_500
      : 0;

  const aiRiskBps =
    parsePercentAfterKeywords(lower, /\b(?:risk|neural|ai)\b[^\d%]{0,24}(\d+(?:\.\d+)?)\s*%/i) ??
    (kind === "AI_REGIME_ESCALATION" ? 7500 : 0);

  const spreadBps =
    parsePercentAfterKeywords(lower, /\b(?:spread|gap|divergence)\b[^\d%]{0,20}(\d+(?:\.\d+)?)\s*%/i) ??
    (kind === "CROSS_CHAIN_REBALANCE" ? 150 : 0);

  const hedgeBps =
    parsePercentAfterKeywords(lower, /\b(?:hedge|hedging|rebalance|rebalancing|move|shift|repay|deleverage|deleveraging|protect)\b[^\d%]{0,20}(\d+(?:\.\d+)?)\s*%/i) ??
    (kind === "CROSS_CHAIN_REBALANCE" ? 2500 : kind === "AI_REGIME_ESCALATION" ? 6000 : 5000);

  // Strict timestamp cooldown parsing (never block counts!)
  let cooldownSeconds = 30;
  const blockMention = lower.match(/(\d+)\s*blocks?/i);
  if (blockMention) {
    const blocks = parseInt(blockMention[1], 10);
    // Convert defensively assuming human expected ~2s blocks, and explicitly warn about Base Sepolia 200ms!
    cooldownSeconds = Math.max(10, Math.min(3600, blocks * 2));
    warnings.push(
      `Converted "${blocks} blocks" into strict Unix timestamp cooldown (${cooldownSeconds}s). Base Sepolia produces 200ms blocks (Denim upgrade), so block-number timers are disallowed.`
    );
  } else {
    const secMatch = lower.match(/(\d+)\s*(?:s|sec|secs|second|seconds)\b/i);
    const minMatch = lower.match(/(\d+)\s*(?:m|min|mins|minute|minutes)\b/i);
    if (secMatch) {
      cooldownSeconds = Math.max(5, Math.min(86400, parseInt(secMatch[1], 10)));
    } else if (minMatch) {
      cooldownSeconds = Math.max(10, Math.min(86400, parseInt(minMatch[1], 10) * 60));
    }
  }

  const adaptiveAiEnabled = !/\b(no\s*ai|disable\s*ai|static\s*only)\b/i.test(lower);
  const callbackGasLimit = 500_000;
  const priceFloorE8 = BigInt(Math.round(priceFloorUsd * 1e8));

  const encodedCalldata = encodeFunctionData({
    abi: CREATE_RULE_ABI,
    functionName: "createRule",
    args: [
      {
        marketId,
        monitoredVault: kind === "HEALTH_FACTOR_RESCUE" ? destinationVault : ("0x0000000000000000000000000000000000000000" as Address),
        destinationChainId: BigInt(destinationChainId),
        destinationVault,
        kind: kindIndex,
        actionType: actionTypeIndex,
        priceFloorE8,
        maxDrawdownBps: Math.min(10_000, Math.max(0, dropBps)),
        minHealthFactorBps: Math.min(50_000, Math.max(0, minHealthFactorBps)),
        aiRiskThresholdBps: Math.min(10_000, Math.max(0, aiRiskBps)),
        spreadThresholdBps: Math.min(10_000, Math.max(0, spreadBps)),
        hedgeBps: Math.min(10_000, Math.max(100, hedgeBps)),
        cooldownSeconds: BigInt(cooldownSeconds),
        expiresAt: 0n,
        callbackGasLimit: BigInt(callbackGasLimit),
        adaptiveAiEnabled,
      },
    ],
  });

  const title =
    kind === "STOP_LOSS_HEDGE"
      ? `${marketSymbol} Stop-Loss Hedge (${(dropBps / 100).toFixed(1)}% -> ${destinationChainName})`
      : kind === "HEALTH_FACTOR_RESCUE"
        ? `${marketSymbol} Health Factor Rescue (< ${(minHealthFactorBps / 10_000).toFixed(2)}x)`
        : kind === "CROSS_CHAIN_REBALANCE"
          ? `${marketSymbol} Base <-> Unichain Spread Rebalancer (>= ${(spreadBps / 100).toFixed(2)}%)`
          : `${marketSymbol} Neural Cascade Circuit Breaker (>= ${(aiRiskBps / 100).toFixed(0)}% Risk)`;

  const rationale = `Compiled for Reactive Omni Lasna (5318007) targeting ${destinationChainName} (${destinationChainId}) with ${callbackGasLimit.toLocaleString()} callback gas (exceeding Omni CallbackProxy 130,000 gas overhead) and strict ${cooldownSeconds}s Unix timestamp cooldown.`;

  return {
    title,
    naturalLanguage: cleanPrompt,
    compilerEngine: "deterministic-nlp",
    marketSymbol,
    marketId,
    destinationChainId,
    destinationChainName,
    destinationVault,
    kindIndex,
    kind,
    actionTypeIndex,
    actionType,
    priceFloorUsd,
    priceFloorE8: priceFloorE8.toString(),
    maxDrawdownBps: Math.min(10_000, Math.max(0, dropBps)),
    minHealthFactorBps,
    aiRiskThresholdBps: Math.min(10_000, Math.max(0, aiRiskBps)),
    spreadThresholdBps: Math.min(10_000, Math.max(0, spreadBps)),
    hedgeBps: Math.min(10_000, Math.max(100, hedgeBps)),
    cooldownSeconds,
    expiresAt: 0,
    callbackGasLimit,
    adaptiveAiEnabled,
    warnings,
    rationale,
    encodedCalldata,
  };
}
