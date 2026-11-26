import { describe, expect, it } from "vitest";
import { decodeFunctionData, keccak256, parseAbi, toHex } from "viem";
import {
  ADVERSARIAL_SCENARIOS,
  computeVaultHealthFactorBps,
  createInitialLabState,
  runAdversarialScenario,
} from "./breakerEngine";
import { DEPLOYED_CONTRACTS, VERIFIED_ONCHAIN_LOOPS } from "./deployments";
import { decodeRawReceiptTuple, MARKET_WETH_USDC } from "./liveRpc";
import { compileNaturalLanguageRule, runNeuralRiskInference } from "./neuralAndCompiler";

describe("Adversarial Breaker Lab Engine (V2 Solidity Guard Mirror)", () => {
  it("blocks unauthorized createRule(), rogue vault targeting, and 8-rule cap flood", () => {
    const init = createInitialLabState();
    const { nextState, result } = runAdversarialScenario(init, "unauthorized_create_rule");
    expect(result.blocked).toBe(true);
    expect(result.steps).toHaveLength(3);
    expect(result.steps[0].soliditySignal).toContain("NotAuthorizedRuleCreator");
    expect(result.steps[1].soliditySignal).toContain("DestinationVaultNotAllowed");
    expect(result.steps[2].soliditySignal).toContain("RuleCapExceeded(8)");
    expect(nextState.vault.volatileCollateralUsd).toBe(100_000);
    expect(nextState.reactive.lReactSpentEstimate).toBe(0);
  });

  it("enforces emergency pause silently on Reactive and reverts on Vault", () => {
    const init = createInitialLabState();
    const { nextState, result } = runAdversarialScenario(init, "paused_vault_trigger");
    expect(result.blocked).toBe(true);
    expect(nextState.reactive.paused).toBe(true);
    expect(nextState.vault.paused).toBe(true);
    expect(result.steps[1].outcome).toBe("SKIPPED_SILENTLY");
    expect(result.steps[2].soliditySignal).toBe("VaultPaused()");
  });

  it("blocks duplicate callback replay, stale 145s spread legs, and 600s EIP-712 TTLs", () => {
    const init = createInitialLabState();
    const { result } = runAdversarialScenario(init, "stale_and_duplicate_replay");
    expect(result.blocked).toBe(true);
    expect(result.steps[0].soliditySignal).toContain("DuplicateCallbackExecution");
    expect(result.steps[1].soliditySignal).toContain("StaleSpreadLegSkipped");
    expect(result.steps[2].soliditySignal).toContain("AdvisementTtlTooLong");
  });

  it("trips circuitBreakerActive on flash crash and hard-locks follow-up callbacks", () => {
    const init = createInitialLabState();
    const { nextState, result } = runAdversarialScenario(init, "flash_crash_breaker_trip");
    expect(result.blocked).toBe(true);
    expect(nextState.vault.circuitBreakerActive).toBe(true);
    expect(nextState.vault.volatileCollateralUsd).toBe(35_000);
    expect(nextState.vault.stableReserveUsd).toBe(90_000);
    expect(result.steps[1].outcome).toBe("REVERTED");
    expect(result.steps[1].soliditySignal).toContain("CircuitBreakerActive");
  });

  it("blocks Base Sepolia 200ms block-drift double-fire under Unix timestamp cooldown", () => {
    const init = createInitialLabState();
    const { result } = runAdversarialScenario(init, "base_200ms_block_drift");
    expect(result.blocked).toBe(true);
    expect(result.steps[1].soliditySignal).toContain("CooldownSkipped");
  });

  it("enforces rolling 1-hour 4-action window cap", () => {
    const init = createInitialLabState();
    const { nextState, result } = runAdversarialScenario(init, "window_action_cap_flood");
    expect(result.blocked).toBe(true);
    expect(nextState.vault.windowActionCount).toBe(4);
    expect(result.steps[1].soliditySignal).toContain("WindowActionCapExceeded");
  });

  it("computes exact vault health factor matching Solidity V2 formula (no divide-before-multiply)", () => {
    const lab = createInitialLabState();
    // (100k * 80 + 25k * 95) * 100 / 60k = 17291 bps (1.7291x)
    expect(computeVaultHealthFactorBps(lab.vault)).toBe(17_291);
    // Post-V1-receipts state: 17.5k WETH, 107.5k USDC, 60k debt -> 19354 bps (~1.94x)
    expect(
      computeVaultHealthFactorBps({
        ...lab.vault,
        volatileCollateralUsd: 17_500,
        stableReserveUsd: 107_500,
        debtUsd: 60_000,
      })
    ).toBe(19_354);
  });

  it("exposes all 6 adversarial scenarios cleanly", () => {
    expect(ADVERSARIAL_SCENARIOS).toHaveLength(6);
  });
});

describe("OmniRisk-MLP-7x12x4 & V2 Natural-Language Rule Compiler", () => {
  it("classifies CALM equilibrium with low risk score and 15% base hedge", () => {
    const res = runNeuralRiskInference({
      priceChangeBps: -25,
      volatilityBps: 110,
      healthFactorBps: 18_500,
      crossChainSpreadBps: 8,
      recentShocks60s: 0,
      drawdownAccelBps: 0,
      secondsSinceLastTick: 1,
    });
    expect(res.regime).toBe("CALM");
    expect(res.riskScoreBps).toBeLessThan(3000);
    expect(res.recommendedHedgeBps).toBe(1500);
  });

  it("classifies severe flash crash + low HF as CASCADE_CRITICAL", () => {
    const res = runNeuralRiskInference({
      priceChangeBps: -750,
      volatilityBps: 1200,
      healthFactorBps: 11_100,
      crossChainSpreadBps: 240,
      recentShocks60s: 4,
      drawdownAccelBps: 450,
      secondsSinceLastTick: 1,
    });
    expect(res.regime).toBe("CASCADE_CRITICAL");
    expect(res.riskScoreBps).toBeGreaterThanOrEqual(8000);
    expect(res.recommendedHedgeBps).toBeGreaterThanOrEqual(5000);
  });

  it("shows monotonic risk score increase from calm to volatile to cascade", () => {
    const calm = runNeuralRiskInference({
      priceChangeBps: -20,
      volatilityBps: 100,
      healthFactorBps: 19_000,
      crossChainSpreadBps: 5,
      recentShocks60s: 0,
      drawdownAccelBps: 0,
      secondsSinceLastTick: 1,
    });
    const mid = runNeuralRiskInference({
      priceChangeBps: -220,
      volatilityBps: 380,
      healthFactorBps: 15_500,
      crossChainSpreadBps: 65,
      recentShocks60s: 1,
      drawdownAccelBps: 70,
      secondsSinceLastTick: 1,
    });
    const crit = runNeuralRiskInference({
      priceChangeBps: -850,
      volatilityBps: 1400,
      healthFactorBps: 10_600,
      crossChainSpreadBps: 300,
      recentShocks60s: 4,
      drawdownAccelBps: 450,
      secondsSinceLastTick: 1,
    });
    expect(mid.riskScoreBps).toBeGreaterThan(calm.riskScoreBps);
    expect(crit.riskScoreBps).toBeGreaterThan(mid.riskScoreBps);
  });

  it("converts block cooldowns to Base Sepolia 200ms-safe Unix seconds and emits valid ABI calldata", () => {
    const compiled = compileNaturalLanguageRule(
      "Hedge 40% of my Base WETH/USDC vault on Unichain if price drops 3.5% with a 15 blocks cooldown"
    );
    expect(compiled.kind).toBe("STOP_LOSS_HEDGE");
    expect(compiled.actionType).toBe("HEDGE_TO_STABLE");
    expect(compiled.cooldownSeconds).toBe(30);
    expect(compiled.callbackGasLimit).toBeGreaterThanOrEqual(450_000);
    expect(compiled.warnings.length).toBe(1);
    expect(compiled.warnings[0]).toMatch(/200ms/);
    expect(compiled.encodedCalldata.startsWith("0x")).toBe(true);
    expect(compiled.encodedCalldata.length).toBeGreaterThan(200);
  });

  it("enforces strict V2 RuleKind <-> ActionType pairing for all 4 rule categories", () => {
    const hf = compileNaturalLanguageRule("Rescue my Base vault if health factor falls below 1.25x by deleveraging 40%");
    expect(hf.kind).toBe("HEALTH_FACTOR_RESCUE");
    expect(hf.actionType).toBe("DELEVERAGE_COLLATERAL");

    const spread = compileNaturalLanguageRule("Auto-rebalance 25% when Base vs Unichain spread exceeds 1.5%");
    expect(spread.kind).toBe("CROSS_CHAIN_REBALANCE");
    expect(spread.actionType).toBe("CROSS_CHAIN_REBALANCE");

    const ai = compileNaturalLanguageRule("Trigger circuit breaker and hedge 65% if neural AI risk exceeds 75%");
    expect(ai.kind).toBe("AI_REGIME_ESCALATION");
    expect(ai.actionType).toBe("CIRCUIT_BREAKER_PAUSE");
  });
});

describe("Live On-Chain Receipt Decoder", () => {
  it("decodes exact Unichain Sepolia V1 receipts #0 and #1 accurately", () => {
    const r0 = decodeRawReceiptTuple({
      receiptId: 0n,
      ruleId: 1n,
      actionType: 0,
      marketId: MARKET_WETH_USDC,
      triggerPriceE8: 3008_00000000n,
      appliedBps: 5000,
      aiRiskScoreBps: 0,
      originTimestamp: 1795518066n,
      callbackTimestamp: 1795518068n,
      endToEndLatencySec: 2n,
      originTxHash: 0x1155b750cbe38ef1ede5727ef1819f7b8fd50625366c836a887e555a83243dd2n,
      collateralBeforeUsdE8: 100_000_00000000n,
      collateralAfterUsdE8: 50_000_00000000n,
      stableAfterUsdE8: 75_000_00000000n,
      debtAfterUsdE8: 60_000_00000000n,
    });
    expect(r0.receiptId).toBe(0);
    expect(r0.actionType).toBe("HEDGE_TO_STABLE");
    expect(r0.endToEndLatencySec).toBe(2);
    expect(r0.collateralBeforeUsd).toBe(100_000);
    expect(r0.collateralAfterUsd).toBe(50_000);
    expect(r0.stableAfterUsd).toBe(75_000);
    expect(r0.debtAfterUsd).toBe(60_000);
    expect(r0.originTxHash).toBe("0x1155b750cbe38ef1ede5727ef1819f7b8fd50625366c836a887e555a83243dd2");

    const r1 = decodeRawReceiptTuple({
      receiptId: 1n,
      ruleId: 3n,
      actionType: 2,
      marketId: MARKET_WETH_USDC,
      triggerPriceE8: 3008_00000000n,
      appliedBps: 6500,
      aiRiskScoreBps: 9120,
      originTimestamp: 1795518068n,
      callbackTimestamp: 1795518071n,
      endToEndLatencySec: 3n,
      originTxHash: 0xb11c83b3b5893ab11209c8f2fb0efd62c3f25bc3d7e2585737cd360e288b7f37n,
      collateralBeforeUsdE8: 50_000_00000000n,
      collateralAfterUsdE8: 17_500_00000000n,
      stableAfterUsdE8: 107_500_00000000n,
      debtAfterUsdE8: 60_000_00000000n,
    });
    expect(r1.receiptId).toBe(1);
    expect(r1.actionType).toBe("CIRCUIT_BREAKER_PAUSE");
    expect(r1.endToEndLatencySec).toBe(3);
    expect(r1.aiRiskScoreBps).toBe(9120);
    expect(r1.collateralAfterUsd).toBe(17_500);
    expect(r1.stableAfterUsd).toBe(107_500);
  });

  it("decodes CROSS_CHAIN_REBALANCE, unknown actionType fallback, and zero originTxHash safely", () => {
    const r3 = decodeRawReceiptTuple({
      receiptId: 2n,
      ruleId: 4n,
      actionType: 3,
      marketId: MARKET_WETH_USDC,
      triggerPriceE8: 3150_00000000n,
      appliedBps: 2500,
      aiRiskScoreBps: 0,
      originTimestamp: 1795518100n,
      callbackTimestamp: 1795518102n,
      endToEndLatencySec: 2n,
      originTxHash: 0n,
      collateralBeforeUsdE8: 100_000_00000000n,
      collateralAfterUsdE8: 75_000_00000000n,
      stableAfterUsdE8: 50_000_00000000n,
      debtAfterUsdE8: 60_000_00000000n,
    });
    expect(r3.actionType).toBe("CROSS_CHAIN_REBALANCE");
    expect(r3.triggerPriceUsd).toBe(3150);
    expect(r3.originTxHash).toBe(`0x${"0".repeat(64)}`);

    const unknown = decodeRawReceiptTuple({
      receiptId: 99n,
      ruleId: 1n,
      actionType: 99,
      marketId: MARKET_WETH_USDC,
      triggerPriceE8: 100_00000000n,
      appliedBps: 100,
      aiRiskScoreBps: 0,
      originTimestamp: 1795518100n,
      callbackTimestamp: 1795518101n,
      endToEndLatencySec: 1n,
      originTxHash: 1n,
      collateralBeforeUsdE8: 0n,
      collateralAfterUsdE8: 0n,
      stableAfterUsdE8: 0n,
      debtAfterUsdE8: 0n,
    });
    expect(unknown.actionType).toBe("ACTION_99");
  });

  it("verifies deployed contract addresses and live proof hashes are well-formed", () => {
    expect(DEPLOYED_CONTRACTS.reactiveGuard).toMatch(/^0x[0-9a-fA-F]{40}$/);
    expect(DEPLOYED_CONTRACTS.unichainGuardVault).toMatch(/^0x[0-9a-fA-F]{40}$/);
    expect(DEPLOYED_CONTRACTS.baseMarketFeed).toMatch(/^0x[0-9a-fA-F]{40}$/);
    expect(VERIFIED_ONCHAIN_LOOPS).toHaveLength(2);
    for (const proof of VERIFIED_ONCHAIN_LOOPS) {
      expect(proof.originTxHash).toMatch(/^0x[0-9a-fA-F]{64}$/);
      expect(proof.reactiveTxHash).toMatch(/^0x[0-9a-fA-F]{64}$/);
      expect(proof.callbackTxHash).toMatch(/^0x[0-9a-fA-F]{64}$/);
      expect(proof.onChainLatencySec).toBe(proof.callbackTimestamp - proof.originTimestamp);
    }
  });
});

describe("Adversarial Thresholds, False-Positive Guardrails & ABI Serialization", () => {
  const CREATE_RULE_ABI = parseAbi([
    "function createRule((bytes32 marketId, address monitoredVault, uint256 destinationChainId, address destinationVault, uint8 kind, uint8 actionType, uint256 priceFloorE8, uint16 maxDrawdownBps, uint16 minHealthFactorBps, uint16 aiRiskThresholdBps, uint16 spreadThresholdBps, uint16 hedgeBps, uint64 cooldownSeconds, uint64 expiresAt, uint64 callbackGasLimit, bool adaptiveAiEnabled) params_) external returns (uint256)",
  ]);

  it("saturates recommendedHedgeBps at 7500 bps ceiling on extreme flash-loan whale drain", () => {
    const res = runNeuralRiskInference({
      priceChangeBps: -950,
      volatilityBps: 1800,
      healthFactorBps: 10_200,
      crossChainSpreadBps: 350,
      recentShocks60s: 5,
      drawdownAccelBps: 600,
      secondsSinceLastTick: 1,
    });
    expect(res.regime).toBe("CASCADE_CRITICAL");
    expect(res.riskScoreBps).toBeGreaterThanOrEqual(9000);
    expect(res.recommendedHedgeBps).toBeLessThanOrEqual(7500);
    expect(res.recommendedHedgeBps).toBeGreaterThanOrEqual(6500);
  });

  it("classifies intermediate ELEVATED and VOLATILE regimes accurately", () => {
    const elevated = runNeuralRiskInference({
      priceChangeBps: -110,
      volatilityBps: 240,
      healthFactorBps: 16_000,
      crossChainSpreadBps: 25,
      recentShocks60s: 1,
      drawdownAccelBps: 30,
      secondsSinceLastTick: 5,
    });
    const volatile = runNeuralRiskInference({
      priceChangeBps: -380,
      volatilityBps: 680,
      healthFactorBps: 13_800,
      crossChainSpreadBps: 130,
      recentShocks60s: 2,
      drawdownAccelBps: 150,
      secondsSinceLastTick: 2,
    });
    expect(["ELEVATED", "VOLATILE"]).toContain(elevated.regime);
    expect(["VOLATILE", "CASCADE_CRITICAL"]).toContain(volatile.regime);
    expect(volatile.riskScoreBps).toBeGreaterThan(elevated.riskScoreBps);
  });

  it("resists false-positive cascade triggers during sharp upside rallies", () => {
    const rally = runNeuralRiskInference({
      priceChangeBps: 850,
      volatilityBps: 160,
      healthFactorBps: 22_000,
      crossChainSpreadBps: 10,
      recentShocks60s: 0,
      drawdownAccelBps: 0,
      secondsSinceLastTick: 1,
    });
    expect(rally.regime).toBe("CALM");
    expect(rally.recommendedHedgeBps).toBe(1500);
  });

  it("sanitizes NaN, Infinity, and negative telemetry without corrupting MLP outputs", () => {
    const malformed = runNeuralRiskInference({
      priceChangeBps: Number.NaN,
      volatilityBps: Number.POSITIVE_INFINITY,
      healthFactorBps: Number.NEGATIVE_INFINITY,
      crossChainSpreadBps: -500,
      recentShocks60s: Number.NaN,
      drawdownAccelBps: Number.NaN,
      secondsSinceLastTick: Number.POSITIVE_INFINITY,
    });
    expect(Number.isFinite(malformed.riskScoreBps)).toBe(true);
    expect(Number.isFinite(malformed.recommendedHedgeBps)).toBe(true);
    expect(Number.isFinite(malformed.confidencePct)).toBe(true);
    const probSum =
      malformed.probabilities.CALM +
      malformed.probabilities.ELEVATED +
      malformed.probabilities.VOLATILE +
      malformed.probabilities.CASCADE_CRITICAL;
    expect(probSum).toBeCloseTo(1, 2);
  });

  it("orders topDrivers by descending impactScore with finite normalized values", () => {
    const res = runNeuralRiskInference({
      priceChangeBps: -600,
      volatilityBps: 900,
      healthFactorBps: 12_000,
      crossChainSpreadBps: 200,
      recentShocks60s: 3,
      drawdownAccelBps: 300,
      secondsSinceLastTick: 1,
    });
    expect(res.topDrivers).toHaveLength(4);
    for (let i = 1; i < res.topDrivers.length; i++) {
      expect(res.topDrivers[i - 1].impactScore).toBeGreaterThanOrEqual(res.topDrivers[i].impactScore);
    }
  });

  it("preserves portfolio conservation and 12-entry log cap across sequential adversarial runs", () => {
    let state = createInitialLabState();
    for (let round = 0; round < 3; round++) {
      for (const s of ADVERSARIAL_SCENARIOS) {
        const res = runAdversarialScenario(state, s.id);
        state = res.nextState;
        expect(state.vault.volatileCollateralUsd + state.vault.stableReserveUsd).toBe(125_000);
      }
    }
    expect(state.logs).toHaveLength(12);
  });

  it("handles computeVaultHealthFactorBps edge cases (zero debt, zero collateral, 100% stable)", () => {
    const base = createInitialLabState().vault;
    expect(computeVaultHealthFactorBps({ ...base, debtUsd: 0 })).toBe(99_999);
    expect(
      computeVaultHealthFactorBps({ ...base, volatileCollateralUsd: 0, stableReserveUsd: 0, debtUsd: 50_000 })
    ).toBe(0);
    // 100k stable * 95 * 100 / 60k = 15833 bps
    expect(
      computeVaultHealthFactorBps({ ...base, volatileCollateralUsd: 0, stableReserveUsd: 100_000, debtUsd: 60_000 })
    ).toBe(15_833);
  });

  it("keeps circuitBreakerActive false during window_action_cap_flood while blocking #5", () => {
    const init = createInitialLabState();
    const { nextState, result } = runAdversarialScenario(init, "window_action_cap_flood");
    expect(nextState.vault.circuitBreakerActive).toBe(false);
    expect(nextState.vault.windowActionCount).toBe(4);
    expect(result.steps[1].outcome).toBe("REVERTED");
  });

  it("resets paused flags and increments receipt/callback counters on flash_crash_breaker_trip", () => {
    let state = createInitialLabState();
    state = runAdversarialScenario(state, "paused_vault_trigger").nextState;
    expect(state.reactive.paused).toBe(true);
    const { nextState } = runAdversarialScenario(state, "flash_crash_breaker_trip");
    expect(nextState.reactive.paused).toBe(false);
    expect(nextState.vault.paused).toBe(false);
    expect(nextState.vault.receiptsCount).toBe(1);
    expect(nextState.reactive.callbacksDispatched).toBe(1);
  });

  it("advances Base Sepolia 200ms blocks by +50 while clockSec advances +15s total", () => {
    const init = createInitialLabState();
    const { nextState } = runAdversarialScenario(init, "base_200ms_block_drift");
    expect(nextState.baseBlockNumber - init.baseBlockNumber).toBe(75); // +25 step +50 drift
    expect(nextState.clockSec - init.clockSec).toBe(15); // +5 step +10 drift
  });

  it("round-trips encoded createRule() ABI calldata cleanly via viem decodeFunctionData", () => {
    const compiled = compileNaturalLanguageRule(
      "Protect my Base WETH/USDC vault on Unichain if price drops 5% or below $2,950; hedge 50% with 45s cooldown"
    );
    const decoded = decodeFunctionData({
      abi: CREATE_RULE_ABI,
      data: compiled.encodedCalldata,
    });
    expect(decoded.functionName).toBe("createRule");
    const params = decoded.args[0];
    expect(params.marketId).toBe(MARKET_WETH_USDC);
    expect(params.destinationChainId).toBe(1301n);
    expect(params.kind).toBe(0);
    expect(params.actionType).toBe(0);
    expect(params.priceFloorE8).toBe(2950_00000000n);
    expect(params.maxDrawdownBps).toBe(500);
    expect(params.hedgeBps).toBe(5000);
    expect(params.cooldownSeconds).toBe(45n);
    expect(params.callbackGasLimit).toBe(500_000n);
    expect(params.adaptiveAiEnabled).toBe(true);
  });

  it("routes WBTC/USDC market and disables adaptive AI when 'static only' is specified", () => {
    const compiled = compileNaturalLanguageRule(
      "Hedge 30% of WBTC/USDC on Base if price drops 6% with 5 minutes cooldown static only"
    );
    expect(compiled.marketSymbol).toBe("WBTC/USDC");
    expect(compiled.marketId).toBe(keccak256(toHex("WBTC/USDC")));
    expect(compiled.destinationChainId).toBe(84532);
    expect(compiled.cooldownSeconds).toBe(300);
    expect(compiled.adaptiveAiEnabled).toBe(false);
  });

  it("clamps extreme cooldown durations to V2 safe [5s, 86400s] bounds", () => {
    const tooShort = compileNaturalLanguageRule("Hedge 20% if price drops 3% with 1s cooldown");
    const tooLong = compileNaturalLanguageRule("Hedge 20% if price drops 3% with 999999s cooldown");
    expect(tooShort.cooldownSeconds).toBe(5);
    expect(tooLong.cooldownSeconds).toBe(86_400);
  });

  it("guards empty or zero-trigger prompts so createRule calldata never hits MissingTriggerCondition", () => {
    const empty = compileNaturalLanguageRule("   ");
    expect(empty.kind).toBe("STOP_LOSS_HEDGE");
    expect(empty.maxDrawdownBps).toBeGreaterThan(0);
    expect(empty.hedgeBps).toBeGreaterThanOrEqual(100);

    const zeroDrop = compileNaturalLanguageRule("Hedge 0% if price drops 0%");
    expect(zeroDrop.maxDrawdownBps).toBe(400);
    expect(zeroDrop.hedgeBps).toBe(100);
    expect(zeroDrop.warnings.some((w) => w.includes("MissingTriggerCondition"))).toBe(true);

    const zeroHf = compileNaturalLanguageRule("Rescue vault if health factor falls below 0x");
    expect(zeroHf.kind).toBe("HEALTH_FACTOR_RESCUE");
    expect(zeroHf.minHealthFactorBps).toBeGreaterThanOrEqual(10_000);
  });

  it("escalates STOP_LOSS_HEDGE actionType to CIRCUIT_BREAKER_PAUSE on 'emergency freeze'", () => {
    const compiled = compileNaturalLanguageRule(
      "Trigger emergency freeze and hedge 60% if WETH drops 7% below $2,800"
    );
    expect(compiled.kind).toBe("STOP_LOSS_HEDGE");
    expect(compiled.actionType).toBe("CIRCUIT_BREAKER_PAUSE");
    expect(compiled.actionTypeIndex).toBe(2);
    expect(compiled.priceFloorUsd).toBe(2800);
    expect(compiled.hedgeBps).toBe(6000);
  });

  it("sets monitoredVault to destinationVault for HEALTH_FACTOR_RESCUE and zero address otherwise", () => {
    const hf = compileNaturalLanguageRule("Rescue my Base vault if health factor falls below 1.2x");
    const sl = compileNaturalLanguageRule("Hedge 35% on Unichain if price drops 4%");
    const hfDecoded = decodeFunctionData({ abi: CREATE_RULE_ABI, data: hf.encodedCalldata });
    const slDecoded = decodeFunctionData({ abi: CREATE_RULE_ABI, data: sl.encodedCalldata });
    expect(hfDecoded.args[0].monitoredVault.toLowerCase()).toBe(DEPLOYED_CONTRACTS.baseGuardVault.toLowerCase());
    expect(slDecoded.args[0].monitoredVault).toBe("0x0000000000000000000000000000000000000000");
  });
});
