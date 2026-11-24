export type RiskRegimeName = "CALM" | "ELEVATED" | "VOLATILE" | "CASCADE_CRITICAL";

export interface ChainTelemetry {
  name: string;
  chainId: number;
  rpcUrl: string;
  systemContract?: string;
  callbackProxy?: string;
  explorer: string;
  blockTimeLabel: string;
  online: boolean;
  latestBlock: number | null;
  latestTimestamp: number | null;
  committedFrontier?: {
    height: number;
    fromSeq: number;
    toSeq: number;
  } | null;
}

export interface NetworkTelemetryResponse {
  queriedAt: number;
  chains: {
    reactiveLasna: ChainTelemetry;
    baseSepolia: ChainTelemetry;
    unichainSepolia: ChainTelemetry;
  };
}

export interface FeatureContribution {
  feature: string;
  normalizedValue: number;
  impactScore: number;
}

export interface NeuralInferenceResult {
  regimeIndex: 0 | 1 | 2 | 3;
  regime: RiskRegimeName;
  probabilities: Record<RiskRegimeName, number>;
  riskScoreBps: number;
  recommendedHedgeBps: number;
  confidencePct: number;
  inferenceLatencyMs: number;
  topDrivers: FeatureContribution[];
  explanation: string;
  modelArchitecture: string;
}

export interface SignedNeuralAdvisement {
  signer: string;
  chainId: number;
  verifyingContract: string;
  advisement: {
    marketId: string;
    regime: number;
    riskScoreBps: number;
    recommendedHedgeBps: number;
    issuedAt: string;
    validUntil: string;
    nonce: string;
  };
  signature: string;
}

export interface CompiledRule {
  title: string;
  naturalLanguage: string;
  compilerEngine: string;
  marketSymbol: string;
  marketId: string;
  destinationChainId: number;
  destinationChainName: string;
  destinationVault: string;
  kind: string;
  actionType: string;
  priceFloorUsd: number;
  maxDrawdownBps: number;
  minHealthFactorBps: number;
  aiRiskThresholdBps: number;
  spreadThresholdBps: number;
  hedgeBps: number;
  cooldownSeconds: number;
  callbackGasLimit: number;
  adaptiveAiEnabled: boolean;
  warnings: string[];
  rationale: string;
  encodedCalldata: string;
}

export interface ActiveRule extends CompiledRule {
  ruleId: number;
  active: boolean;
  lastTriggeredAt: number;
  triggerCount: number;
}

export interface ExecutionEventLog {
  id: string;
  scenario: string;
  timestamp: number;
  originChain: string;
  originChainId: number;
  destinationChain: string;
  destinationChainId: number;
  ruleId: number;
  ruleTitle: string;
  actionType: string;
  priceBeforeUsd: number;
  priceAfterUsd: number;
  appliedHedgeBps: number;
  neuralRegime: RiskRegimeName;
  neuralRiskBps: number;
  originTxHash: string;
  reactiveTxHash: string;
  callbackTxHash: string;
  hopsMs: {
    originConfirmMs: number;
    reactiveFinalityMs: number;
    callbackDeliveryMs: number;
    totalOmniMs: number;
    legacyEstimatedMs: number;
    latencySavedMs: number;
  };
  vaultDelta: {
    volatileBeforeUsd: number;
    volatileAfterUsd: number;
    stableAfterUsd: number;
    debtAfterUsd: number;
    circuitBreakerActive: boolean;
  };
  signedAdvisement: SignedNeuralAdvisement;
  mode: "live-testnet" | "omni-simulator";
}

export interface AppStateResponse {
  deployments: Record<string, string | undefined>;
  markets: {
    "WETH/USDC": {
      baseSepoliaPriceUsd: number;
      unichainSepoliaPriceUsd: number;
      crossChainSpreadBps: number;
    };
  };
  vault: {
    marketSymbol: string;
    volatileCollateralUsd: number;
    stableReserveUsd: number;
    debtUsd: number;
    rebalancedVolumeUsd: number;
    circuitBreakerActive: boolean;
    lastActionTimestamp: number;
    healthFactorBps: number;
    totalAssetsUsd: number;
  };
  neural: NeuralInferenceResult;
  signedAdvisement: SignedNeuralAdvisement | null;
  rules: ActiveRule[];
  executions: ExecutionEventLog[];
  latencySummary: {
    totalExecutions: number;
    avgOmniMs: number;
    avgLegacyMs: number;
    speedupFactor: number;
  };
}
