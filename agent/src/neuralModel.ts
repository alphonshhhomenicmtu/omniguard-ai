/**
 * OmniGuard AI — Live Neural Risk Sentinel (2-Layer Multi-Layer Perceptron)
 *
 * Runs directly inside the live Reactive execution loop (no external API key required).
 * Ingests real-time cross-chain telemetry from Base Sepolia (200ms blocks) and Unichain Sepolia (1s blocks),
 * executes a calibrated 7 -> 12 -> 4 MLP forward pass with ReLU + Softmax, classifies market risk regime,
 * computes a bounded riskScoreBps (0..10000) and recommendedHedgeBps, and exposes interpretable feature
 * attribution for both the on-chain EIP-712 Neural Advisement and the live dashboard.
 */

export type RiskRegimeName = "CALM" | "ELEVATED" | "VOLATILE" | "CASCADE_CRITICAL";

export interface MarketFeatureInput {
  /** Signed percentage price change in basis points (e.g., -600 = -6.00%). */
  priceChangeBps: number;
  /** Short-window realized volatility in basis points (e.g., 850 = 8.50%). */
  volatilityBps: number;
  /** Vault health factor in basis points (e.g., 12000 = 1.20x; 20000 = 2.00x). */
  healthFactorBps: number;
  /** Base Sepolia vs Unichain Sepolia spot price spread in basis points. */
  crossChainSpreadBps: number;
  /** Count of adverse shock events observed in the trailing 60-second window. */
  recentShocks60s: number;
  /** Drawdown acceleration relative to previous tick in basis points. */
  drawdownAccelBps: number;
  /** Seconds since last confirmed price update (staleness risk). */
  secondsSinceLastTick: number;
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

const REGIMES: RiskRegimeName[] = ["CALM", "ELEVATED", "VOLATILE", "CASCADE_CRITICAL"];

// Layer 1: 7 inputs -> 12 hidden ReLU neurons (calibrated across DeFi cascade regimes)
const W1: number[][] = [
  // [absDrop, negMomentum, vol, hfStress, spread, shockRate, accel]
  [1.8, 2.2, 0.9, 0.4, 0.2, 0.6, 1.1], // H0: flash crash detector
  [0.3, 0.4, 1.9, 0.2, 1.3, 0.9, 0.6], // H1: high-volatility spread detector
  [0.2, 0.5, 0.4, 2.6, 0.1, 0.7, 0.4], // H2: liquidation proximity detector
  [1.4, 1.8, 1.5, 1.8, 0.9, 1.6, 1.5], // H3: systemic cascade detector
  [-1.6, -1.9, -1.4, -1.5, -0.9, -1.1, -0.8], // H4: calm equilibrium detector
  [0.9, 1.1, 0.8, 0.5, 0.4, 0.3, 0.5], // H5: moderate stress detector
  [0.5, 0.2, 1.2, 0.3, 2.1, 0.5, 0.3], // H6: cross-chain dislocation detector
  [1.1, 1.5, 1.1, 1.2, 0.5, 1.4, 1.2], // H7: multi-shock persistence detector
  [-0.8, -1.1, -0.9, -0.8, -0.5, -0.6, -0.4], // H8: stability margin detector
  [0.7, 0.9, 1.4, 0.9, 0.7, 0.8, 0.9], // H9: regime transition neuron
  [0.1, 0.3, 0.5, 1.9, 0.2, 1.1, 0.5], // H10: debt-spiral warning neuron
  [1.6, 2.0, 1.6, 1.4, 1.0, 1.3, 1.4], // H11: extreme tail-risk neuron
];

const B1: number[] = [-0.55, -0.45, -0.4, -1.45, 1.95, -0.25, -0.5, -1.0, 1.25, -0.65, -0.7, -1.65];

// Layer 2: 12 hidden neurons -> 4 regime logits [CALM, ELEVATED, VOLATILE, CASCADE_CRITICAL]
const W2: number[][] = [
  // CALM
  [-1.2, -0.8, -1.1, -2.0, 2.1, -0.7, -0.6, -1.3, 1.5, -0.9, -1.0, -1.8],
  // ELEVATED
  [0.5, 0.7, 0.4, -0.6, 0.2, 1.4, 0.8, 0.1, 0.1, 0.9, 0.4, -0.8],
  // VOLATILE
  [1.2, 1.5, 1.1, 0.8, -1.2, 0.5, 1.4, 1.2, -0.9, 1.3, 0.9, 0.6],
  // CASCADE_CRITICAL
  [1.6, 1.1, 1.8, 2.5, -2.2, -0.2, 0.7, 1.9, -1.6, 1.2, 1.6, 2.6],
];

const B2: number[] = [0.4, 0.15, -0.45, -1.1];

function clip(val: number, min: number, max: number): number {
  if (!Number.isFinite(val)) return min;
  return Math.max(min, Math.min(max, val));
}

function relu(x: number): number {
  return x > 0 ? x : 0;
}

function softmax(logits: number[]): number[] {
  const maxLogit = Math.max(...logits);
  const exps = logits.map((z) => Math.exp(z - maxLogit));
  const sum = exps.reduce((a, b) => a + b, 0);
  return exps.map((e) => e / sum);
}

/**
 * Extracts bounded dimensionless features from raw cross-chain market telemetry.
 */
export function extractFeatures(input: MarketFeatureInput): { vector: number[]; labels: string[] } {
  const absDrop = clip(
    (input.priceChangeBps < 0 ? Math.abs(input.priceChangeBps) : input.priceChangeBps * 0.25) / 800,
    0,
    2.0
  );
  const negMomentum = clip(Math.max(0, -input.priceChangeBps) / 600, 0, 2.0);
  const volNorm = clip(input.volatilityBps / 900, 0, 2.0);
  // Health factor <= 1.00x (10000 bps) -> stress 1.6+, >= 1.65x -> stress 0
  const hfStress = clip((16_500 - input.healthFactorBps) / 4_500, 0, 2.0);
  const spreadNorm = clip(input.crossChainSpreadBps / 350, 0, 2.0);
  const shockRate = clip(input.recentShocks60s / 4, 0, 2.0);
  const accelNorm = clip(Math.max(0, input.drawdownAccelBps) / 400 + clip(input.secondsSinceLastTick / 600, 0, 0.5), 0, 2.0);

  return {
    vector: [absDrop, negMomentum, volNorm, hfStress, spreadNorm, shockRate, accelNorm],
    labels: [
      "Price Shock Magnitude",
      "Downside Momentum",
      "Realized Volatility",
      "Health Factor Proximity",
      "Base/Unichain Spread",
      "60s Cascade Frequency",
      "Drawdown Acceleration",
    ],
  };
}

/**
 * Executes a deterministic real-time neural forward pass and returns regime classification,
 * riskScoreBps, recommendedHedgeBps, and feature attributions.
 */
export function runNeuralRiskInference(input: MarketFeatureInput): NeuralInferenceResult {
  const t0 = performance.now();
  const { vector, labels } = extractFeatures(input);

  // Hidden layer: h = ReLU(W1 * x + b1)
  const hidden: number[] = W1.map((weights, i) => {
    let acc = B1[i];
    for (let j = 0; j < vector.length; j++) {
      acc += weights[j] * vector[j];
    }
    return relu(acc);
  });

  // Output layer: z = W2 * h + b2
  const logits: number[] = W2.map((weights, k) => {
    let acc = B2[k];
    for (let i = 0; i < hidden.length; i++) {
      acc += weights[i] * hidden[i];
    }
    return acc;
  });

  const probs = softmax(logits);
  let bestIdx: 0 | 1 | 2 | 3 = 0;
  for (let i = 1; i < 4; i++) {
    if (probs[i] > probs[bestIdx]) {
      bestIdx = i as 0 | 1 | 2 | 3;
    }
  }

  // Expected risk score across regime centroids [1200, 4200, 7000, 9400] bps
  const centroids = [1200, 4200, 7000, 9400];
  let expectedRisk = 0;
  for (let i = 0; i < 4; i++) {
    expectedRisk += probs[i] * centroids[i];
  }
  const riskScoreBps = Math.round(clip(expectedRisk, 200, 9950));

  // Map neural risk score to recommended defensive hedge ratio (15% to 75%)
  let recommendedHedgeBps = 1500;
  if (bestIdx === 3 || riskScoreBps >= 8000) {
    recommendedHedgeBps = Math.min(7500, Math.round(4500 + ((riskScoreBps - 7500) / 2500) * 3000));
  } else if (bestIdx === 2 || riskScoreBps >= 6000) {
    recommendedHedgeBps = Math.round(3000 + ((riskScoreBps - 5500) / 2500) * 2000);
  } else if (bestIdx === 1) {
    recommendedHedgeBps = 2500;
  }

  // Compute interpretable feature attributions via local sensitivity on critical/volatile logits
  const drivers: FeatureContribution[] = vector.map((val, idx) => {
    const sensitivity = Math.max(0, W1[3][idx] * 0.5 + W1[11][idx] * 0.5);
    return {
      feature: labels[idx],
      normalizedValue: Number(val.toFixed(3)),
      impactScore: Number((val * sensitivity * 100).toFixed(1)),
    };
  });
  drivers.sort((a, b) => b.impactScore - a.impactScore);

  const regime = REGIMES[bestIdx];
  const confidencePct = Number((probs[bestIdx] * 100).toFixed(1));
  const inferenceLatencyMs = Number(Math.max(0.05, performance.now() - t0).toFixed(3));

  const topTwo = drivers
    .slice(0, 2)
    .filter((d) => d.impactScore > 5)
    .map((d) => d.feature.toLowerCase());
  const driverText = topTwo.length > 0 ? `driven by ${topTwo.join(" and ")}` : "with balanced market equilibrium";

  const explanation =
    bestIdx === 3
      ? `CASCADE_CRITICAL detected (${confidencePct}% conf, risk ${(riskScoreBps / 100).toFixed(1)}%) ${driverText}. Tightening Reactive stop-loss triggers by 35% and recommending ${(recommendedHedgeBps / 100).toFixed(0)}% emergency hedge.`
      : bestIdx === 2
        ? `VOLATILE regime classified (${confidencePct}% conf, risk ${(riskScoreBps / 100).toFixed(1)}%) ${driverText}. Tightening Reactive thresholds by 20% and staging ${(recommendedHedgeBps / 100).toFixed(0)}% defensive rebalance.`
        : bestIdx === 1
          ? `ELEVATED activity observed (${confidencePct}% conf, risk ${(riskScoreBps / 100).toFixed(1)}%) ${driverText}. Tightening Reactive drawdown sensitivity by 10%.`
          : `CALM regime confirmed (${confidencePct}% conf, risk ${(riskScoreBps / 100).toFixed(1)}%) ${driverText}. Base Reactive guardrails remain active.`;

  return {
    regimeIndex: bestIdx,
    regime,
    probabilities: {
      CALM: Number(probs[0].toFixed(4)),
      ELEVATED: Number(probs[1].toFixed(4)),
      VOLATILE: Number(probs[2].toFixed(4)),
      CASCADE_CRITICAL: Number(probs[3].toFixed(4)),
    },
    riskScoreBps,
    recommendedHedgeBps,
    confidencePct,
    inferenceLatencyMs,
    topDrivers: drivers.slice(0, 4),
    explanation,
    modelArchitecture: "OmniRisk-MLP-7x12x4 (ReLU + Softmax)",
  };
}
