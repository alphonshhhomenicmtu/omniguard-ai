/**
 * OmniGuard AI V2 — Adversarial Breaker Lab Engine (Deterministic Solidity Guard Mirror)
 *
 * Faithfully mirrors the V2 security guards implemented in:
 *   - contracts/src/reactive/OmniGuardReactive.sol
 *   - contracts/src/destination/OmniGuardVault.sol
 *   - contracts/src/origin/OmniMarketFeed.sol
 *
 * Strictly badged SIMULATED (LOCAL EVM MODEL) in the UI — never produces fake live-testnet hashes.
 */

export type AdversarialScenarioId =
  | "unauthorized_create_rule"
  | "paused_vault_trigger"
  | "stale_and_duplicate_replay"
  | "flash_crash_breaker_trip"
  | "base_200ms_block_drift"
  | "window_action_cap_flood";

export interface BreakerLabState {
  clockSec: number;
  baseBlockNumber: number;
  reactive: {
    owner: string;
    paused: boolean;
    activeRulesCount: number;
    maxRulesPerMarket: number;
    maxTotalRules: number;
    lastStopLossTriggeredAt: number;
    stopLossCooldownSec: number;
    callbacksDispatched: number;
    lReactSpentEstimate: number;
  };
  vault: {
    paused: boolean;
    volatileCollateralUsd: number;
    stableReserveUsd: number;
    debtUsd: number;
    circuitBreakerActive: boolean;
    windowStartSec: number;
    windowActionCount: number;
    maxActionsPerWindow: number;
    maxSingleActionBps: number;
    executedKeys: string[];
    receiptsCount: number;
  };
  logs: AdversarialRunRecord[];
}

export interface AdversarialStepTrace {
  actor: string;
  contract: "OmniGuardReactive" | "OmniGuardVault" | "OmniMarketFeed";
  call: string;
  outcome: "REVERTED" | "SKIPPED_SILENTLY" | "EXECUTED";
  soliditySignal: string;
  v1Vulnerability: string;
  v2Protection: string;
}

export interface AdversarialRunRecord {
  id: string;
  scenarioId: AdversarialScenarioId;
  title: string;
  timestampSec: number;
  blocked: boolean;
  summary: string;
  steps: AdversarialStepTrace[];
}

export const ADVERSARIAL_SCENARIOS: Array<{
  id: AdversarialScenarioId;
  title: string;
  shortLabel: string;
  severity: "CRITICAL (C1)" | "HIGH (C2)" | "HIGH (H1/M1)" | "MEDIUM (200ms)";
  description: string;
}> = [
  {
    id: "unauthorized_create_rule",
    title: "Unauthorized createRule() Shared-Vault Hijack + Dust Flood",
    shortLabel: "Unauthorized createRule()",
    severity: "CRITICAL (C1)",
    description:
      "Stranger tries to register a 100% hedge rule against Unichain vault, then an operator probes an unallowlisted rogue chain and exceeds the 8-rule per-market cap.",
  },
  {
    id: "paused_vault_trigger",
    title: "Emergency Pause on Reactive & Vault During Flash Crash",
    shortLabel: "Paused-Vault Trigger",
    severity: "CRITICAL (C1)",
    description:
      "Engages emergency pause() on Reactive and Vault, then injects a -6.2% Base flash crash to verify 0 wasted ReactiveContractReverted gas and hard VaultPaused() revert.",
  },
  {
    id: "stale_and_duplicate_replay",
    title: "Duplicate Callback Replay, Stale 145s Spread Leg & 600s EIP-712 TTL",
    shortLabel: "Stale / Duplicate Replay",
    severity: "HIGH (H1/M1)",
    description:
      "Replays an already-settled (txHash, logIndex, ruleId) callback, submits a stale cross-chain spread leg (>120s age), and signs an unbounded 600s EIP-712 advisement.",
  },
  {
    id: "flash_crash_breaker_trip",
    title: "Flash-Crash Circuit Breaker Trip & Follow-Up Drain Lockout",
    shortLabel: "Flash-Crash Breaker Trip",
    severity: "HIGH (C2)",
    description:
      "Executes a CASCADE_CRITICAL 65% shift that arms circuitBreakerActive=true, then fires a follow-up 50% hedge and rebalance to prove full lockout until owner clears it.",
  },
  {
    id: "base_200ms_block_drift",
    title: "Base Sepolia 200ms Block-Drift Double-Fire Probe",
    shortLabel: "200ms Block-Drift Guard",
    severity: "MEDIUM (200ms)",
    description:
      "Advances +50 Base Sepolia blocks with only +10s elapsed wall-clock time under a 30s cooldown to prove block.number drift can never trigger double-hedging.",
  },
  {
    id: "window_action_cap_flood",
    title: "Rolling 1-Hour 4-Action Vault Circuit Breaker Cap",
    shortLabel: "1h Action Cap Flood",
    severity: "HIGH (C2)",
    description:
      "Attempts 5 back-to-back callbacks inside one 3600s window to prove the V2 vault enforces WindowActionCapExceeded(WETH/USDC, 4) before collateral churn.",
  },
];

export function computeVaultHealthFactorBps(vault: BreakerLabState["vault"]): number {
  if (vault.debtUsd <= 0) return 99_999;
  const weighted = vault.volatileCollateralUsd * 80 + vault.stableReserveUsd * 95;
  return Math.floor((weighted * 100) / vault.debtUsd);
}

export function createInitialLabState(): BreakerLabState {
  return {
    clockSec: 1_795_518_100,
    baseBlockNumber: 62_981_000,
    reactive: {
      owner: "0x06EC...4c03",
      paused: false,
      activeRulesCount: 3,
      maxRulesPerMarket: 8,
      maxTotalRules: 32,
      lastStopLossTriggeredAt: 0,
      stopLossCooldownSec: 30,
      callbacksDispatched: 0,
      lReactSpentEstimate: 0,
    },
    vault: {
      paused: false,
      volatileCollateralUsd: 100_000,
      stableReserveUsd: 25_000,
      debtUsd: 60_000,
      circuitBreakerActive: false,
      windowStartSec: 0,
      windowActionCount: 0,
      maxActionsPerWindow: 4,
      maxSingleActionBps: 8000,
      executedKeys: ["0x1155b750:0:1"],
      receiptsCount: 0,
    },
    logs: [],
  };
}

export function runAdversarialScenario(
  prev: BreakerLabState,
  scenarioId: AdversarialScenarioId
): { nextState: BreakerLabState; result: AdversarialRunRecord } {
  const next: BreakerLabState = {
    ...prev,
    reactive: { ...prev.reactive },
    vault: { ...prev.vault, executedKeys: [...prev.vault.executedKeys] },
    logs: [...prev.logs],
  };
  next.clockSec += 5;
  next.baseBlockNumber += 25;

  const id = `adv-${next.logs.length + 1}-${scenarioId}`;
  let record: AdversarialRunRecord;

  if (scenarioId === "unauthorized_create_rule") {
    const steps: AdversarialStepTrace[] = [
      {
        actor: "0xAttacker...DEAD",
        contract: "OmniGuardReactive",
        call: "createRule({ market: WETH/USDC, priceFloor: $99,999, hedgeBps: 10000 })",
        outcome: "REVERTED",
        soliditySignal: "NotAuthorizedRuleCreator(0xAttacker...DEAD)",
        v1Vulnerability: "V1 createRule() was permissionless; any wallet could move the shared Unichain vault and drain lREACT.",
        v2Protection: "V2 enforces onlyRuleCreator (owner or allowlisted operator). Zero state mutation, 0 lREACT spent.",
      },
      {
        actor: "0xOperator...ALLOW",
        contract: "OmniGuardReactive",
        call: "createRule({ destinationChainId: 999999, destinationVault: 0xRogue... })",
        outcome: "REVERTED",
        soliditySignal: "DestinationVaultNotAllowed(999999, 0xRogue...)",
        v1Vulnerability: "V1 accepted any non-zero chainId/vault, enabling lREACT InDebt griefing.",
        v2Protection: "V2 checks allowedDestinationVaults[chainId][vault] before registering any rule.",
      },
      {
        actor: "0xOperator...ALLOW",
        contract: "OmniGuardReactive",
        call: "createRule(#9 on WETH/USDC after 8 active rules)",
        outcome: "REVERTED",
        soliditySignal: "RuleCapExceeded(8)",
        v1Vulnerability: "V1 iterated unbounded _marketRuleIds[], risking Lasna's ~900,000 gas ceiling.",
        v2Protection: "V2 caps 8 active rules/market (32 total) and swap-and-pop prunes deactivated rules.",
      },
    ];
    record = {
      id,
      scenarioId,
      title: "Unauthorized createRule() & Allowlist / Cap Guard",
      timestampSec: next.clockSec,
      blocked: true,
      summary: "All 3 takeover/griefing vectors reverted before touching vault balances or spending lREACT.",
      steps,
    };
  } else if (scenarioId === "paused_vault_trigger") {
    next.reactive.paused = true;
    next.vault.paused = true;
    const steps: AdversarialStepTrace[] = [
      {
        actor: "0xOwner...4c03",
        contract: "OmniGuardReactive",
        call: "pause() + OmniGuardVault.pause()",
        outcome: "EXECUTED",
        soliditySignal: "PauseStatusChanged(true)",
        v1Vulnerability: "V1 had no global emergency stop switch on Reactive or Vault.",
        v2Protection: "Owner arms instant emergency pause across both Lasna and destination vault.",
      },
      {
        actor: "SYSTEM (0x8888...8888)",
        contract: "OmniGuardReactive",
        call: "react(PriceUpdated: WETH -6.20%)",
        outcome: "SKIPPED_SILENTLY",
        soliditySignal: "returns cleanly (0 callbacks, 0 ReactiveContractReverted)",
        v1Vulnerability: "Reverting inside react() wastes Lasna lREACT via ReactiveContractReverted.",
        v2Protection: "Paused react() exits silently on line 1 with zero callback requests.",
      },
      {
        actor: "CallbackProxy (0x775c...66C1)",
        contract: "OmniGuardVault",
        call: "executeProtection(reactiveSender, rule=1, HEDGE_TO_STABLE, 5000 bps)",
        outcome: "REVERTED",
        soliditySignal: "VaultPaused()",
        v1Vulnerability: "In-flight callbacks could still mutate vault positions during incident response.",
        v2Protection: "whenNotPaused modifier blocks both executeProtection() and executeCrossChainRebalance().",
      },
    ];
    record = {
      id,
      scenarioId,
      title: "Emergency Pause Containment Verified",
      timestampSec: next.clockSec,
      blocked: true,
      summary: "Paused reactive engine returned silently (0 wasted gas) and paused vault hard-reverted in-flight callbacks.",
      steps,
    };
  } else if (scenarioId === "stale_and_duplicate_replay") {
    const replayKey = next.vault.executedKeys[0] ?? "0x1155b750:0:1";
    const steps: AdversarialStepTrace[] = [
      {
        actor: "CallbackProxy (0x775c...66C1)",
        contract: "OmniGuardVault",
        call: `executeProtection(originTx=0x1155b750..., logIndex=0, ruleId=1) [key=${replayKey}]`,
        outcome: "REVERTED",
        soliditySignal: "DuplicateCallbackExecution(0x1155b750..., 0, 1)",
        v1Vulnerability: "V1 replay key omitted logIndex, risking same-tx multi-log collisions.",
        v2Protection: "V2 keys replay on keccak256(originTxHash, logIndex, ruleId) and blocks exact replays cleanly.",
      },
      {
        actor: "SYSTEM (0x8888...8888)",
        contract: "OmniGuardReactive",
        call: "react(Unichain PriceUpdated $3,100 vs 145s-stale Base leg $3,200)",
        outcome: "SKIPPED_SILENTLY",
        soliditySignal: "StaleSpreadLegSkipped(ruleId=4, legSkew=145s > MAX_SPREAD_LEG_AGE_SECONDS=120s)",
        v1Vulnerability: "V1 compared latestPriceByChain without checking latestPriceTimestampByChain.",
        v2Protection: "V2 enforces <= 120s freshness between primary and secondary origin price legs.",
      },
      {
        actor: "0xRelayer...9999",
        contract: "OmniMarketFeed",
        call: "submitSignedNeuralRegime({ validUntil: now + 600s, regime: CASCADE_CRITICAL })",
        outcome: "REVERTED",
        soliditySignal: "AdvisementTtlTooLong(validUntil, now + 180s)",
        v1Vulnerability: "V1 allowed unbounded validUntil so a rotated signer could pin CASCADE_CRITICAL indefinitely.",
        v2Protection: "V2 caps advisement TTL at 180s, issuedAt skew at +/-120s, and invalidates old signer snapshots on rotation.",
      },
    ];
    record = {
      id,
      scenarioId,
      title: "Replay, Stale Leg & Unbounded TTL Guards Verified",
      timestampSec: next.clockSec,
      blocked: true,
      summary: "Duplicate callback, 145s stale cross-chain spread leg, and 600s neural advisement all rejected cleanly.",
      steps,
    };
  } else if (scenarioId === "flash_crash_breaker_trip") {
    // Ensure clean unpaused state for the trip demonstration
    next.reactive.paused = false;
    next.vault.paused = false;
    next.vault.circuitBreakerActive = false;

    const shiftUsd = Math.round((next.vault.volatileCollateralUsd * 6500) / 10_000);
    const volBefore = next.vault.volatileCollateralUsd;
    next.vault.volatileCollateralUsd -= shiftUsd;
    next.vault.stableReserveUsd += shiftUsd;
    next.vault.circuitBreakerActive = true;
    next.vault.receiptsCount += 1;
    next.reactive.callbacksDispatched += 1;
    next.vault.windowActionCount = Math.min(next.vault.maxActionsPerWindow, next.vault.windowActionCount + 1);
    if (next.vault.windowStartSec === 0) next.vault.windowStartSec = next.clockSec;

    const steps: AdversarialStepTrace[] = [
      {
        actor: "OmniRisk-MLP -> OmniGuardReactive",
        contract: "OmniGuardVault",
        call: `executeProtection(CIRCUIT_BREAKER_PAUSE, 6500 bps, risk=9120) [$${volBefore.toLocaleString()} -> $${next.vault.volatileCollateralUsd.toLocaleString()} WETH]`,
        outcome: "EXECUTED",
        soliditySignal: "ProtectionExecuted(action=CIRCUIT_BREAKER_PAUSE, circuitBreakerActive=true)",
        v1Vulnerability: "V1 set circuitBreakerActive=true but NEVER checked it on subsequent callbacks.",
        v2Protection: "V2 executes the 65% defensive shift AND locks the market circuit breaker immediately.",
      },
      {
        actor: "CallbackProxy (0x775c...66C1)",
        contract: "OmniGuardVault",
        call: "executeProtection(rule=1, HEDGE_TO_STABLE, 5000 bps) [Follow-up attack/churn]",
        outcome: "REVERTED",
        soliditySignal: "CircuitBreakerActive(keccak256(\"WETH/USDC\"))",
        v1Vulnerability: "V1 allowed unlimited follow-up rules to keep shifting the position after breaker tripped.",
        v2Protection: "V2 hard-reverts both executeProtection() and executeCrossChainRebalance() until owner calls clearCircuitBreaker().",
      },
    ];
    record = {
      id,
      scenarioId,
      title: "Circuit Breaker Tripped & Follow-Up Callbacks Locked Out",
      timestampSec: next.clockSec,
      blocked: true,
      summary: `Defensive 65% shift moved $${shiftUsd.toLocaleString()} to USDC and locked circuitBreakerActive=true; follow-up callback hard-reverted.`,
      steps,
    };
  } else if (scenarioId === "base_200ms_block_drift") {
    next.reactive.paused = false;
    next.reactive.lastStopLossTriggeredAt = next.clockSec;
    const tFirst = next.clockSec;
    next.baseBlockNumber += 50; // 50 Base Sepolia 200ms blocks = only 10 seconds!
    next.clockSec += 10;

    const steps: AdversarialStepTrace[] = [
      {
        actor: "Base Sepolia Feed",
        contract: "OmniGuardReactive",
        call: `PriceUpdated(-4.5%) at block #${next.baseBlockNumber - 50}, ts=${tFirst}`,
        outcome: "EXECUTED",
        soliditySignal: "ReactionDispatched(ruleId=1, cooldownSeconds=30s)",
        v1Vulnerability: "Block-number timers on Base Sepolia (200ms blocks) expire 10x faster than 2s L2 assumptions.",
        v2Protection: "OmniGuard records lastTriggeredAt = originTimestamp (Unix seconds), never block.number.",
      },
      {
        actor: "Base Sepolia Feed (+50 blocks, ONLY +10s elapsed)",
        contract: "OmniGuardReactive",
        call: `PriceUpdated(-4.5%) at block #${next.baseBlockNumber}, ts=${next.clockSec}`,
        outcome: "SKIPPED_SILENTLY",
        soliditySignal: `CooldownSkipped(ruleId=1, originTs=${next.clockSec}, nextEligibleAt=${tFirst + 30})`,
        v1Vulnerability: "A broken 15-block timer would double-fire after just 3 seconds on Base Denim.",
        v2Protection: "Strict uint64 Unix timestamp check blocks premature execution until full 30s elapsed.",
      },
    ];
    record = {
      id,
      scenarioId,
      title: "Base Sepolia 200ms Block-Drift Cooldown Guard",
      timestampSec: next.clockSec,
      blocked: true,
      summary: "+50 fast Base Sepolia blocks in +10s stayed locked under 30s Unix timestamp cooldown (0 double-fires).",
      steps,
    };
  } else {
    // window_action_cap_flood
    next.reactive.paused = false;
    next.vault.paused = false;
    next.vault.circuitBreakerActive = false;
    next.vault.windowStartSec = next.clockSec;
    next.vault.windowActionCount = next.vault.maxActionsPerWindow;

    const steps: AdversarialStepTrace[] = [
      {
        actor: "CallbackProxy (0x775c...66C1)",
        contract: "OmniGuardVault",
        call: "Callbacks #1..#4 within 3600s rolling window (10% each)",
        outcome: "EXECUTED",
        soliditySignal: `windowActionCount reached ${next.vault.maxActionsPerWindow}/${next.vault.maxActionsPerWindow}`,
        v1Vulnerability: "V1 had no rolling rate cap on vault callbacks per hour.",
        v2Protection: "V2 tracks windowStartTimestamp + windowActionCount per market in a 3600s window.",
      },
      {
        actor: "CallbackProxy (0x775c...66C1)",
        contract: "OmniGuardVault",
        call: "Callback #5 inside same 3600s rolling window",
        outcome: "REVERTED",
        soliditySignal: `WindowActionCapExceeded(WETH/USDC, ${next.vault.maxActionsPerWindow})`,
        v1Vulnerability: "A flapping feed or misconfigured rule could churn collateral repeatedly.",
        v2Protection: "Callback #5 hard-reverts until 3600s window rolls over or owner resets via clearCircuitBreaker().",
      },
    ];
    record = {
      id,
      scenarioId,
      title: "Rolling 1-Hour Vault Circuit Breaker Cap Enforced",
      timestampSec: next.clockSec,
      blocked: true,
      summary: `Blocked callback #5 inside rolling 3600s window (cap=${next.vault.maxActionsPerWindow}/hr).`,
      steps,
    };
  }

  next.logs = [record, ...next.logs].slice(0, 12);
  return { nextState: next, result: record };
}
