import assert from "node:assert/strict";
import test from "node:test";
import { verifyTypedData, type Address } from "viem";
import { getNeuralSignerAccount, signNeuralAdvisement } from "./eip712Signer.js";
import { runNeuralRiskInference } from "./neuralModel.js";
import { compileNaturalLanguageRule, marketIdFromSymbol } from "./ruleCompiler.js";

test("OmniRisk-MLP classifies calm market with low risk score", () => {
  const res = runNeuralRiskInference({
    priceChangeBps: -25,
    volatilityBps: 110,
    healthFactorBps: 18_500,
    crossChainSpreadBps: 8,
    recentShocks60s: 0,
    drawdownAccelBps: 0,
    secondsSinceLastTick: 1,
  });

  assert.equal(res.regime, "CALM");
  assert.ok(res.riskScoreBps < 3000, `expected calm risk < 3000, got ${res.riskScoreBps}`);
  assert.equal(res.recommendedHedgeBps, 1500);
});

test("OmniRisk-MLP escalates severe flash crash + low HF to CASCADE_CRITICAL", () => {
  const res = runNeuralRiskInference({
    priceChangeBps: -750,
    volatilityBps: 1200,
    healthFactorBps: 11_100,
    crossChainSpreadBps: 240,
    recentShocks60s: 4,
    drawdownAccelBps: 450,
    secondsSinceLastTick: 1,
  });

  assert.equal(res.regime, "CASCADE_CRITICAL");
  assert.ok(res.riskScoreBps >= 8000, `expected critical risk >= 8000, got ${res.riskScoreBps}`);
  assert.ok(res.recommendedHedgeBps >= 5000, `expected hedge >= 5000, got ${res.recommendedHedgeBps}`);
});

test("Natural-language compiler converts block cooldowns to Base Sepolia timestamp seconds with warning", async () => {
  const compiled = await compileNaturalLanguageRule(
    "Protect my Base WETH/USDC vault on Unichain if price drops 4.5% or below $3020; hedge 55% with a 15 blocks cooldown"
  );

  assert.equal(compiled.kind, "STOP_LOSS_HEDGE");
  assert.equal(compiled.destinationChainId, 1301);
  assert.equal(compiled.maxDrawdownBps, 450);
  assert.equal(compiled.priceFloorUsd, 3020);
  assert.equal(compiled.hedgeBps, 5500);
  assert.equal(compiled.cooldownSeconds, 30);
  assert.equal(compiled.warnings.length, 1);
  assert.match(compiled.warnings[0], /200ms/);
  assert.ok(compiled.encodedCalldata.startsWith("0x"));

  const hfRule = await compileNaturalLanguageRule(
    "Rescue my Base vault if health factor falls below 1.25x by deleveraging 40% of debt with a 60s cooldown"
  );
  assert.equal(hfRule.kind, "HEALTH_FACTOR_RESCUE");
  assert.equal(hfRule.actionType, "DELEVERAGE_COLLATERAL");
  assert.equal(hfRule.destinationChainId, 84532);
  assert.equal(hfRule.hedgeBps, 4000);

  const aiRule = await compileNaturalLanguageRule(
    "Trigger emergency circuit breaker on Unichain and hedge 65% whenever neural AI risk exceeds 75% with a 45s cooldown"
  );
  assert.equal(aiRule.kind, "AI_REGIME_ESCALATION");
  assert.equal(aiRule.actionType, "CIRCUIT_BREAKER_PAUSE");
  assert.equal(aiRule.aiRiskThresholdBps, 7500);
  assert.equal(aiRule.hedgeBps, 6500);
});

test("EIP-712 signer fails closed when NEURAL_SIGNER_PRIVATE_KEY is unset", () => {
  assert.throws(() => getNeuralSignerAccount(undefined), /fail-closed/i);
  assert.throws(() => getNeuralSignerAccount("not-a-key"), /fail-closed/i);
});

test("EIP-712 Neural Advisement signature verifies cleanly in explicit simulated mode", async () => {
  const verifyingContract = "0x1234567890123456789012345678901234567890" as Address;
  const signed = await signNeuralAdvisement({
    chainId: 84532,
    verifyingContract,
    allowEphemeralSimulationKey: true,
    advisement: {
      marketId: marketIdFromSymbol("WETH/USDC"),
      regime: 3,
      riskScoreBps: 8900,
      recommendedHedgeBps: 6500,
      issuedAt: 1_795_500_000n,
      validUntil: 1_795_500_180n,
      nonce: 0n,
    },
  });

  assert.equal(signed.simulatedSigner, true);
  const valid = await verifyTypedData({
    address: signed.signer,
    domain: {
      name: "OmniGuardMarketFeed",
      version: "1",
      chainId: 84532,
      verifyingContract,
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
    message: {
      marketId: signed.advisement.marketId,
      regime: signed.advisement.regime,
      riskScoreBps: signed.advisement.riskScoreBps,
      recommendedHedgeBps: signed.advisement.recommendedHedgeBps,
      issuedAt: BigInt(signed.advisement.issuedAt),
      validUntil: BigInt(signed.advisement.validUntil),
      nonce: BigInt(signed.advisement.nonce),
    },
    signature: signed.signature,
  });

  assert.equal(valid, true);
});
