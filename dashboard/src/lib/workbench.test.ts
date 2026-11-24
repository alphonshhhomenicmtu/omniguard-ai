import { describe, expect, it } from "vitest";
import {
  ADVERSARIAL_SCENARIOS,
  computeVaultHealthFactorBps,
  createInitialLabState,
  runAdversarialScenario,
} from "./breakerEngine";
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
});
