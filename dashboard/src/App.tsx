import { useCallback, useEffect, useState } from "react";
import {
  Activity,
  AlertTriangle,
  ArrowRight,
  Brain,
  CheckCircle2,
  Clock,
  Cpu,
  Flame,
  RefreshCw,
  Shield,
  ShieldAlert,
  Sparkles,
  Terminal,
  Zap,
} from "lucide-react";
import type {
  AppStateResponse,
  CompiledRule,
  NetworkTelemetryResponse,
  RiskRegimeName,
} from "./types";

const PRESET_PROMPTS = [
  {
    label: "Base -> Unichain Stop-Loss",
    prompt:
      "Protect my Base WETH/USDC vault on Unichain if price drops 4.5% or below $3,020 by hedging 55% to USDC with a 30s cooldown and adaptive AI",
  },
  {
    label: "200ms Block Warning Test",
    prompt:
      "Hedge 40% of my Base WETH/USDC vault on Unichain if price drops 3.5% with a 15 blocks cooldown",
  },
  {
    label: "Cross-Chain Spread Arb",
    prompt:
      "Auto-rebalance 30% of WETH/USDC on Unichain when Base vs Unichain spread exceeds 1.25% with a 20s cooldown",
  },
  {
    label: "AI Cascade Breaker",
    prompt:
      "Trigger emergency circuit breaker on Unichain and hedge 70% whenever neural AI risk exceeds 78% with a 45s cooldown",
  },
];

function shortHash(hash?: string | null): string {
  if (!hash) return "—";
  if (hash.length <= 16) return hash;
  return `${hash.slice(0, 10)}...${hash.slice(-6)}`;
}

function fmtUsd(val: number): string {
  return `$${val.toLocaleString("en-US", { maximumFractionDigits: 0 })}`;
}

function regimeBadgeClass(regime: RiskRegimeName): string {
  if (regime === "CASCADE_CRITICAL") return "pill pill-crimson";
  if (regime === "VOLATILE") return "pill pill-amber";
  if (regime === "ELEVATED") return "pill pill-violet";
  return "pill pill-omni";
}

function regimeTighteningLabel(regime: RiskRegimeName): string {
  if (regime === "CASCADE_CRITICAL") return "-35% tighter drawdown trigger";
  if (regime === "VOLATILE") return "-20% tighter drawdown trigger";
  if (regime === "ELEVATED") return "-10% tighter drawdown trigger";
  return "Base threshold (0% shift)";
}

export default function App() {
  const [state, setState] = useState<AppStateResponse | null>(null);
  const [telemetry, setTelemetry] = useState<NetworkTelemetryResponse | null>(null);
  const [busyScenario, setBusyScenario] = useState<string | null>(null);
  const [prompt, setPrompt] = useState(PRESET_PROMPTS[0].prompt);
  const [compiledPreview, setCompiledPreview] = useState<CompiledRule | null>(null);
  const [compiling, setCompiling] = useState(false);
  const [deployingRule, setDeployingRule] = useState(false);

  const fetchState = useCallback(async () => {
    const res = await fetch("/api/state");
    if (res.ok) {
      setState(await res.json());
    }
  }, []);

  const fetchTelemetry = useCallback(async () => {
    const res = await fetch("/api/network-telemetry");
    if (res.ok) {
      setTelemetry(await res.json());
    }
  }, []);

  useEffect(() => {
    fetchState();
    fetchTelemetry();
    const t = setInterval(fetchTelemetry, 12_000);
    return () => clearInterval(t);
  }, [fetchState, fetchTelemetry]);

  const handleSimulate = async (scenario: string) => {
    setBusyScenario(scenario);
    try {
      await fetch("/api/simulate-event", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ scenario }),
      });
      await fetchState();
    } finally {
      setBusyScenario(null);
    }
  };

  const handleReset = async () => {
    setBusyScenario("reset");
    try {
      await fetch("/api/reset-demo", { method: "POST" });
      await fetchState();
    } finally {
      setBusyScenario(null);
    }
  };

  const handleCompile = async (customPrompt?: string) => {
    const text = customPrompt ?? prompt;
    setCompiling(true);
    try {
      const res = await fetch("/api/compile-rule", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ prompt: text }),
      });
      if (res.ok) {
        const json = await res.json();
        setCompiledPreview(json.compiled);
      }
    } finally {
      setCompiling(false);
    }
  };

  const handleDeployRule = async () => {
    setDeployingRule(true);
    try {
      const res = await fetch("/api/rules", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ prompt }),
      });
      if (res.ok) {
        setCompiledPreview(null);
        await fetchState();
      }
    } finally {
      setDeployingRule(false);
    }
  };

  const handleToggleRule = async (ruleId: number) => {
    await fetch(`/api/rules/${ruleId}/toggle`, { method: "POST" });
    await fetchState();
  };

  const latestExec = state?.executions[0] ?? null;
  const vault = state?.vault;
  const neural = state?.neural;
  const market = state?.markets["WETH/USDC"];
  const totalAssets = vault ? Math.max(1, vault.totalAssetsUsd) : 125_000;
  const volatilePct = vault ? (vault.volatileCollateralUsd / totalAssets) * 100 : 80;
  const stablePct = vault ? (vault.stableReserveUsd / totalAssets) * 100 : 20;

  const avgOmniMs = state?.latencySummary.avgOmniMs ?? 2180;
  const avgLegacyMs = state?.latencySummary.avgLegacyMs ?? 9450;
  const omniOriginPct = latestExec ? (latestExec.hopsMs.originConfirmMs / avgLegacyMs) * 100 : 2.5;
  const omniReactivePct = latestExec ? (latestExec.hopsMs.reactiveFinalityMs / avgLegacyMs) * 100 : 11;
  const omniDestPct = latestExec ? (latestExec.hopsMs.callbackDeliveryMs / avgLegacyMs) * 100 : 10.5;

  return (
    <div className="app-shell">
      {/* Top Command Header */}
      <header className="topbar">
        <div className="brand">
          <div className="brand-icon">
            <Shield size={24} />
          </div>
          <div>
            <h1>
              OmniGuard AI
              <span className="pill pill-omni">REACTIVE OMNI ~1s</span>
              <span className="pill pill-violet">NEURAL IN THE LOOP</span>
            </h1>
            <p className="brand-sub">
              Autonomous Cross-Chain DeFi Protection &amp; Neural Policy Sentinel — Base Sepolia (200ms) &harr; Reactive Lasna (5318007) &harr; Unichain Sepolia (1301)
            </p>
          </div>
        </div>
        <div style={{ display: "flex", gap: 8, alignItems: "center", flexWrap: "wrap" }}>
          <span className="pill pill-base">
            <Clock size={12} /> Timestamp-Only Cooldowns (200ms Safe)
          </span>
          <button className="btn btn-ghost" onClick={fetchTelemetry}>
            <RefreshCw size={13} /> Sync Live RPC
          </button>
        </div>
      </header>

      {/* Live 3-Chain RPC Telemetry Strip */}
      <section className="chain-strip">
        {[
          {
            key: "base",
            data: telemetry?.chains.baseSepolia,
            fallbackName: "Base Sepolia (84532)",
            badgeClass: "pill-base",
            role: "ORIGIN / DEST • 200ms",
            addrLabel: "Proxy 0x476F...3585",
          },
          {
            key: "lasna",
            data: telemetry?.chains.reactiveLasna,
            fallbackName: "Reactive Lasna (5318007)",
            badgeClass: "pill-omni",
            role: "OMNI COMETBFT • ~1.0s",
            addrLabel: "SYSTEM 0x8888...8888",
          },
          {
            key: "unichain",
            data: telemetry?.chains.unichainSepolia,
            fallbackName: "Unichain Sepolia (1301)",
            badgeClass: "pill-unichain",
            role: "DEST / SPREAD • 1.0s",
            addrLabel: "Proxy 0x775c...66C1",
          },
        ].map((item) => (
          <div className="chain-card" key={item.key}>
            <div className="chain-meta">
              <div className="chain-title">
                <span className={`dot ${item.data?.online === false ? "dot-offline" : ""}`} />
                <span>{item.data?.name ?? item.fallbackName}</span>
                <span className={`pill ${item.badgeClass}`}>{item.role}</span>
              </div>
              <div className="chain-detail">
                Chain {item.data?.chainId ?? "—"} &middot; {item.addrLabel}
              </div>
            </div>
            <div className="chain-block">
              <div className="chain-block-num">
                {item.data?.latestBlock ? `#${item.data.latestBlock.toLocaleString()}` : "Syncing..."}
              </div>
              <div className="chain-block-sub">
                {item.data?.committedFrontier
                  ? `RNK Seq ${item.data.committedFrontier.toSeq.toLocaleString()}`
                  : item.data?.online
                    ? "Live RPC Head"
                    : "Polling RPC"}
              </div>
            </div>
          </div>
        ))}
      </section>

      {/* Hero Row: Cross-Chain Trigger Deck + Latency Benchmark & Vault Allocation */}
      <section className="grid-2">
        <div className="card">
          <div className="card-header">
            <div>
              <div className="card-title">
                <Zap size={18} color="#00e5a0" />
                Every Second Counts — Live Cross-Chain Execution Loop
              </div>
              <div className="card-subtitle">
                Fire an origin shock to execute OmniMarketFeed &rarr; OmniRisk-MLP (EIP-712) &rarr; OmniGuardReactive &rarr; OmniGuardVault
              </div>
            </div>
            <button className="btn btn-ghost" onClick={handleReset} disabled={busyScenario !== null}>
              <RefreshCw size={12} /> Reset Vault
            </button>
          </div>

          <div className="trigger-grid">
            <button
              className="btn btn-danger"
              disabled={busyScenario !== null}
              onClick={() => handleSimulate("flash_crash")}
            >
              <div>
                <span>Flash Crash (-6.2% WETH)</span>
                <span className="btn-sub">Base 200ms &rarr; Lasna &rarr; Unichain Hedge</span>
              </div>
              <Flame size={17} color="#fb7185" />
            </button>
            <button
              className="btn"
              disabled={busyScenario !== null}
              onClick={() => handleSimulate("health_breach")}
            >
              <div>
                <span>Health Factor Drop (1.18x)</span>
                <span className="btn-sub">Triggers 40% Debt Deleveraging Rescue</span>
              </div>
              <ShieldAlert size={17} color="#f59e0b" />
            </button>
            <button
              className="btn"
              disabled={busyScenario !== null}
              onClick={() => handleSimulate("cross_chain_spread")}
            >
              <div>
                <span>Base / Unichain 3.3% Spread</span>
                <span className="btn-sub">Cross-Pool Liquidity Rebalance Callback</span>
              </div>
              <Activity size={17} color="#38bdf8" />
            </button>
            <button
              className="btn btn-danger"
              disabled={busyScenario !== null}
              onClick={() => handleSimulate("neural_cascade")}
            >
              <div>
                <span>Neural Cascade Escalation</span>
                <span className="btn-sub">EIP-712 Critical Regime &rarr; Circuit Breaker</span>
              </div>
              <Brain size={17} color="#a78bfa" />
            </button>
          </div>

          {/* 3-Hop Pipeline Visualizer */}
          <div className="pipeline">
            <div className="hop-box base">
              <span className="hop-label">1. Origin Event</span>
              <span className="hop-chain">{latestExec?.originChain ?? "Base Sepolia"}</span>
              <span className="hop-latency">
                {latestExec ? `${latestExec.hopsMs.originConfirmMs} ms` : "210 ms"}
              </span>
              <span className="hop-hash">
                tx: {shortHash(latestExec?.originTxHash)}
              </span>
            </div>
            <div className="hop-arrow">
              <ArrowRight size={18} />
            </div>
            <div className="hop-box omni">
              <span className="hop-label">2. Reactive Omni react()</span>
              <span className="hop-chain">Lasna CometBFT</span>
              <span className="hop-latency">
                {latestExec ? `${latestExec.hopsMs.reactiveFinalityMs} ms` : "1,040 ms"}
              </span>
              <span className="hop-hash">
                tx: {shortHash(latestExec?.reactiveTxHash)}
              </span>
            </div>
            <div className="hop-arrow">
              <ArrowRight size={18} />
            </div>
            <div className="hop-box unichain">
              <span className="hop-label">3. Callback Settlement</span>
              <span className="hop-chain">{latestExec?.destinationChain ?? "Unichain Sepolia"}</span>
              <span className="hop-latency">
                {latestExec ? `${latestExec.hopsMs.callbackDeliveryMs} ms` : "1,020 ms"}
              </span>
              <span className="hop-hash">
                tx: {shortHash(latestExec?.callbackTxHash)}
              </span>
            </div>
          </div>

          {/* Spot Telemetry Bar */}
          <div className="kpi-row">
            <div className="kpi">
              <div className="kpi-label">Base WETH/USDC</div>
              <div className="kpi-value" style={{ color: "#38bdf8" }}>
                ${market ? market.baseSepoliaPriceUsd.toLocaleString() : "3,200"}
              </div>
              <div className="kpi-sub">Origin feed (200ms blocks)</div>
            </div>
            <div className="kpi">
              <div className="kpi-label">Unichain WETH/USDC</div>
              <div className="kpi-value" style={{ color: "#f472b6" }}>
                ${market ? market.unichainSepoliaPriceUsd.toLocaleString() : "3,198.5"}
              </div>
              <div className="kpi-sub">
                Spread: {market ? (market.crossChainSpreadBps / 100).toFixed(2) : "0.05"}%
              </div>
            </div>
            <div className="kpi">
              <div className="kpi-label">Omni Speedup vs Legacy</div>
              <div className="kpi-value" style={{ color: "#00e5a0" }}>
                {state?.latencySummary.speedupFactor ?? 4.33}x
              </div>
              <div className="kpi-sub">
                Saved {((avgLegacyMs - avgOmniMs) / 1000).toFixed(2)}s / loop
              </div>
            </div>
          </div>
        </div>

        {/* Right Panel: Latency Waterfall & Protected Vault State */}
        <div className="card">
          <div className="card-header">
            <div>
              <div className="card-title">
                <Clock size={18} color="#38bdf8" />
                Full-Loop Latency &amp; Protected Vault State
              </div>
              <div className="card-subtitle">
                Why Reactive Omni (~1s CometBFT) unlocks sub-3s liquidation defense impossible on legacy 7s blocks
              </div>
            </div>
            {vault?.circuitBreakerActive ? (
              <span className="pill pill-crimson">CIRCUIT BREAKER ON</span>
            ) : (
              <span className="pill pill-omni">VAULT ARMED</span>
            )}
          </div>

          <div className="waterfall">
            <div className="bar-row">
              <div className="bar-meta">
                <span style={{ color: "#00e5a0", fontWeight: 700 }}>
                  Reactive Omni (Base + Lasna + Dest)
                </span>
                <strong>{(avgOmniMs / 1000).toFixed(2)}s</strong>
              </div>
              <div className="bar-track">
                <div className="seg-base" style={{ width: `${Math.max(3, omniOriginPct)}%` }} />
                <div className="seg-omni" style={{ width: `${Math.max(10, omniReactivePct)}%` }} />
                <div className="seg-unichain" style={{ width: `${Math.max(8, omniDestPct)}%` }} />
              </div>
            </div>

            <div className="bar-row">
              <div className="bar-meta">
                <span style={{ color: "#94a3b8" }}>Legacy Reactive (~7s blocks — Liquidation Risk)</span>
                <span style={{ color: "#f59e0b" }}>{(avgLegacyMs / 1000).toFixed(2)}s</span>
              </div>
              <div className="bar-track">
                <div className="seg-legacy" style={{ width: "100%" }} />
              </div>
            </div>
          </div>

          <div style={{ display: "flex", flexDirection: "column", gap: 8, marginTop: 4 }}>
            <div style={{ display: "flex", justifyContent: "space-between", fontSize: "0.78rem" }}>
              <span style={{ fontWeight: 600 }}>Destination OmniGuardVault Portfolio</span>
              <span className="mono" style={{ color: "#00e5a0" }}>
                Total Protected: {fmtUsd(vault?.totalAssetsUsd ?? 125_000)}
              </span>
            </div>
            <div className="vault-bar">
              <div
                style={{ width: `${volatilePct}%`, background: "linear-gradient(90deg, #38bdf8, #6366f1)" }}
                title="Volatile WETH Collateral"
              />
              <div
                style={{ width: `${stablePct}%`, background: "linear-gradient(90deg, #00e5a0, #10b981)" }}
                title="Protected USDC Reserve"
              />
            </div>
            <div className="vault-legend">
              <span>WETH Exposure: {fmtUsd(vault?.volatileCollateralUsd ?? 100_000)} ({volatilePct.toFixed(0)}%)</span>
              <span>USDC Safe Reserve: {fmtUsd(vault?.stableReserveUsd ?? 25_000)} ({stablePct.toFixed(0)}%)</span>
            </div>
          </div>

          <div className="kpi-row">
            <div className="kpi">
              <div className="kpi-label">Health Factor</div>
              <div
                className="kpi-value"
                style={{
                  color: (vault?.healthFactorBps ?? 17_290) < 13_000 ? "#fb7185" : "#00e5a0",
                }}
              >
                {vault ? `${(vault.healthFactorBps / 10_000).toFixed(2)}x` : "1.73x"}
              </div>
              <div className="kpi-sub">Rescue floor: 1.25x</div>
            </div>
            <div className="kpi">
              <div className="kpi-label">Active Debt</div>
              <div className="kpi-value">{fmtUsd(vault?.debtUsd ?? 60_000)}</div>
              <div className="kpi-sub">Auto-deleveraged on breach</div>
            </div>
            <div className="kpi">
              <div className="kpi-label">Rebalanced Vol</div>
              <div className="kpi-value" style={{ color: "#f472b6" }}>
                {fmtUsd(vault?.rebalancedVolumeUsd ?? 0)}
              </div>
              <div className="kpi-sub">Cross-chain spread arb</div>
            </div>
          </div>
        </div>
      </section>

      {/* Middle Row: Live Neural Risk Sentinel + Natural-Language Rule Studio */}
      <section className="grid-equal">
        {/* Left: Live Neural Risk Engine (Reactive Meets AI) */}
        <div className="card">
          <div className="card-header">
            <div>
              <div className="card-title">
                <Cpu size={18} color="#a78bfa" />
                Reactive Meets AI — Live Neural Risk Sentinel
              </div>
              <div className="card-subtitle">
                {neural?.modelArchitecture ?? "OmniRisk-MLP-7x12x4 (ReLU + Softmax)"} &middot; Inference {neural?.inferenceLatencyMs ?? 0.12}ms
              </div>
            </div>
            {neural && <span className={regimeBadgeClass(neural.regime)}>{neural.regime}</span>}
          </div>

          <div className="kpi-row">
            <div className="kpi">
              <div className="kpi-label">Neural Risk Score</div>
              <div
                className="kpi-value"
                style={{
                  color:
                    (neural?.riskScoreBps ?? 1200) >= 7500
                      ? "#fb7185"
                      : (neural?.riskScoreBps ?? 1200) >= 5000
                        ? "#f59e0b"
                        : "#00e5a0",
                }}
              >
                {neural ? `${(neural.riskScoreBps / 100).toFixed(1)}%` : "12.0%"}
              </div>
              <div className="kpi-sub">{neural?.riskScoreBps ?? 1200} / 10,000 bps</div>
            </div>
            <div className="kpi">
              <div className="kpi-label">AI Hedge Target</div>
              <div className="kpi-value" style={{ color: "#a78bfa" }}>
                {neural ? `${(neural.recommendedHedgeBps / 100).toFixed(0)}%` : "15%"}
              </div>
              <div className="kpi-sub">Overrides rule if higher</div>
            </div>
            <div className="kpi">
              <div className="kpi-label">Adaptive Tightening</div>
              <div className="kpi-value" style={{ fontSize: "0.86rem", color: "#38bdf8", marginTop: 8 }}>
                {neural ? regimeTighteningLabel(neural.regime) : "Base threshold"}
              </div>
              <div className="kpi-sub">Applied on Lasna react()</div>
            </div>
          </div>

          <div className="prob-list">
            {(
              [
                ["CALM", "#00e5a0"],
                ["ELEVATED", "#a78bfa"],
                ["VOLATILE", "#f59e0b"],
                ["CASCADE_CRITICAL", "#fb7185"],
              ] as const
            ).map(([label, color]) => {
              const pct = ((neural?.probabilities[label] ?? 0) * 100);
              return (
                <div className="prob-row" key={label}>
                  <span>{label}</span>
                  <div className="prob-track">
                    <div className="prob-fill" style={{ width: `${pct}%`, background: color }} />
                  </div>
                  <span style={{ textAlign: "right" }}>{pct.toFixed(1)}%</span>
                </div>
              );
            })}
          </div>

          <div className="explanation-box">{neural?.explanation}</div>

          {state?.signedAdvisement && (
            <div className="eip712-box">
              <div>
                EIP-712 Signer: <strong>{shortHash(state.signedAdvisement.signer)}</strong>
              </div>
              <div>
                Nonce / Chain: <strong>#{state.signedAdvisement.advisement.nonce} &middot; Base 84532</strong>
              </div>
              <div style={{ gridColumn: "1 / -1" }}>
                Verified Signature: <strong>{shortHash(state.signedAdvisement.signature)}</strong> (checked on-chain via{" "}
                <span style={{ color: "#00e5a0" }}>ecrecover</span>)
              </div>
            </div>
          )}
        </div>

        {/* Right: Natural-Language Policy Compiler (Set It and Forget It) */}
        <div className="card">
          <div className="card-header">
            <div>
              <div className="card-title">
                <Sparkles size={18} color="#00e5a0" />
                Set It and Forget It — Natural-Language Rule Studio
              </div>
              <div className="card-subtitle">
                Author plain-English cross-chain guardrails compiled directly to Reactive Lasna ABI calldata
              </div>
            </div>
            <span className="pill pill-omni">NO SOLIDITY NEEDED</span>
          </div>

          <div className="preset-row">
            {PRESET_PROMPTS.map((p) => (
              <button
                key={p.label}
                className="preset-chip"
                onClick={() => {
                  setPrompt(p.prompt);
                  handleCompile(p.prompt);
                }}
              >
                {p.label}
              </button>
            ))}
          </div>

          <textarea
            className="prompt-input"
            value={prompt}
            onChange={(e) => setPrompt(e.target.value)}
            placeholder="Describe your protection or rebalancing rule in plain English..."
          />

          <div style={{ display: "flex", gap: 10 }}>
            <button className="btn" style={{ flex: 1, justifyContent: "center" }} onClick={() => handleCompile()} disabled={compiling}>
              <Terminal size={15} /> {compiling ? "Compiling..." : "Compile & Preview Calldata"}
            </button>
            <button
              className="btn btn-primary"
              style={{ flex: 1 }}
              onClick={handleDeployRule}
              disabled={deployingRule}
            >
              <CheckCircle2 size={15} /> {deployingRule ? "Registering..." : "Activate Guard Rule"}
            </button>
          </div>

          {compiledPreview ? (
            <div className="compiled-preview">
              <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", gap: 8 }}>
                <strong>{compiledPreview.title}</strong>
                <span className="pill pill-base">
                  {compiledPreview.destinationChainName} ({compiledPreview.destinationChainId})
                </span>
              </div>

              {compiledPreview.warnings.map((w, idx) => (
                <div className="warning-banner" key={idx}>
                  <AlertTriangle size={13} style={{ verticalAlign: "-2px", marginRight: 6 }} />
                  {w}
                </div>
              ))}

              <div className="eip712-box">
                <div>
                  Rule Kind: <strong>{compiledPreview.kind}</strong>
                </div>
                <div>
                  Action: <strong>{compiledPreview.actionType}</strong>
                </div>
                <div>
                  Hedge / Rebalance: <strong>{(compiledPreview.hedgeBps / 100).toFixed(1)}%</strong>
                </div>
                <div>
                  Timestamp Cooldown: <strong>{compiledPreview.cooldownSeconds}s (Unix)</strong>
                </div>
                <div>
                  Callback Gas: <strong>{compiledPreview.callbackGasLimit.toLocaleString()}</strong>
                </div>
                <div>
                  Adaptive AI: <strong>{compiledPreview.adaptiveAiEnabled ? "Enabled" : "Static"}</strong>
                </div>
              </div>

              <div className="calldata-box">
                createRule() calldata: {compiledPreview.encodedCalldata.slice(0, 124)}...
              </div>
            </div>
          ) : (
            <div className="explanation-box" style={{ borderLeftColor: "#00e5a0" }}>
              Click any preset above or type your own rule — e.g. mention a block count like <em>&ldquo;15 blocks cooldown&rdquo;</em> to see the automatic Base Sepolia 200ms timestamp safety guard convert it into Unix seconds and generate exact <span className="mono">OmniGuardReactive.createRule()</span> calldata.
            </div>
          )}
        </div>
      </section>

      {/* Bottom Row: Active On-Chain Rules + Execution Receipt Ledger */}
      <section className="grid-equal">
        <div className="card">
          <div className="card-header">
            <div>
              <div className="card-title">
                <Shield size={18} color="#38bdf8" />
                Active Guard Rules on OmniGuardReactive
              </div>
              <div className="card-subtitle">
                Evaluated autonomously inside react() on Reactive Lasna (5318007)
              </div>
            </div>
            <span className="pill pill-base">{state?.rules.length ?? 0} RULES</span>
          </div>

          <div className="table-wrap">
            <table>
              <thead>
                <tr>
                  <th>ID</th>
                  <th>Policy</th>
                  <th>Destination</th>
                  <th>Cooldown</th>
                  <th>Fires</th>
                  <th>Status</th>
                </tr>
              </thead>
              <tbody>
                {state?.rules.map((r) => (
                  <tr key={r.ruleId}>
                    <td className="mono">#{r.ruleId}</td>
                    <td>
                      <div style={{ fontWeight: 600 }}>{r.title}</div>
                      <div className="mono" style={{ fontSize: "0.68rem", color: "#64748b" }}>
                        {r.actionType} &middot; {(r.hedgeBps / 100).toFixed(0)}% &middot; {r.adaptiveAiEnabled ? "AI-Adaptive" : "Static"}
                      </div>
                    </td>
                    <td>
                      <span className={`pill ${r.destinationChainId === 1301 ? "pill-unichain" : "pill-base"}`}>
                        {r.destinationChainId === 1301 ? "Unichain" : "Base"}
                      </span>
                    </td>
                    <td className="mono">{r.cooldownSeconds}s</td>
                    <td className="mono">{r.triggerCount}</td>
                    <td>
                      <button
                        className={`pill ${r.active ? "pill-omni" : "pill-amber"}`}
                        style={{ cursor: "pointer" }}
                        onClick={() => handleToggleRule(r.ruleId)}
                      >
                        {r.active ? "ACTIVE" : "PAUSED"}
                      </button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>

        <div className="card">
          <div className="card-header">
            <div>
              <div className="card-title">
                <Activity size={18} color="#f472b6" />
                Origin &rarr; Reactive &rarr; Callback Audit Trail
              </div>
              <div className="card-subtitle">
                Chronological full-loop proof log with hop-by-hop latency measurements
              </div>
            </div>
            <span className="pill pill-unichain">{state?.executions.length ?? 0} LOOPS</span>
          </div>

          {!state || state.executions.length === 0 ? (
            <div className="empty-state">
              No protection loops triggered yet. Click <strong>Flash Crash (-6.2% WETH)</strong> or{" "}
              <strong>Neural Cascade Escalation</strong> above to inspect a full 3-hop Reactive Omni execution trace.
            </div>
          ) : (
            <div className="table-wrap">
              <table>
                <thead>
                  <tr>
                    <th>Route</th>
                    <th>Action &amp; AI</th>
                    <th>3-Hop Latency</th>
                    <th>Proof Hashes</th>
                  </tr>
                </thead>
                <tbody>
                  {state.executions.map((ex) => (
                    <tr key={ex.id}>
                      <td>
                        <div style={{ fontWeight: 600 }}>{ex.originChain} &rarr; {ex.destinationChain}</div>
                        <div className="mono" style={{ fontSize: "0.68rem", color: "#64748b" }}>
                          Rule #{ex.ruleId} &middot; {ex.scenario}
                        </div>
                      </td>
                      <td>
                        <span className={regimeBadgeClass(ex.neuralRegime)}>{ex.neuralRegime}</span>
                        <div className="mono" style={{ fontSize: "0.68rem", color: "#94a3b8", marginTop: 4 }}>
                          {ex.actionType} ({(ex.appliedHedgeBps / 100).toFixed(0)}%)
                        </div>
                      </td>
                      <td className="mono">
                        <div style={{ color: "#00e5a0", fontWeight: 700 }}>
                          {(ex.hopsMs.totalOmniMs / 1000).toFixed(2)}s
                        </div>
                        <div style={{ fontSize: "0.67rem", color: "#64748b" }}>
                          {ex.hopsMs.originConfirmMs} + {ex.hopsMs.reactiveFinalityMs} + {ex.hopsMs.callbackDeliveryMs}ms
                        </div>
                      </td>
                      <td className="mono" style={{ fontSize: "0.68rem", color: "#94a3b8", whiteSpace: "nowrap" }}>
                        <div>O: {shortHash(ex.originTxHash)}</div>
                        <div>R: {shortHash(ex.reactiveTxHash)}</div>
                        <div>C: {shortHash(ex.callbackTxHash)}</div>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </div>
      </section>
    </div>
  );
}
