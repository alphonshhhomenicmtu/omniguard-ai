export interface VerifiedLoopProof {
  id: string;
  name: string;
  ruleId: number;
  actionType: string;
  appliedBps: number;
  aiRiskScoreBps?: number;
  originChain: string;
  originTxHash: `0x${string}`;
  originBlock?: number;
  originTimestamp: number;
  reactiveTxHash: `0x${string}`;
  reactiveBlock: number;
  callbackTxHash: `0x${string}`;
  callbackBlock: number;
  callbackTimestamp: number;
  receiptId: number;
  onChainLatencySec: number;
  wallClockMsNote?: string;
}

export const OMNI_NETWORKS = {
  baseSepolia: {
    name: "Base Sepolia",
    shortName: "Base",
    chainId: 84532,
    rpcUrl: "https://sepolia.base.org",
    explorer: "https://sepolia.basescan.org",
    callbackProxy: "0x476F44b11F5C942c58f4c8E3d0300E5710743585" as `0x${string}`,
    cadence: "200ms (Denim)",
  },
  reactiveLasna: {
    name: "Reactive Lasna (Omni)",
    shortName: "Lasna",
    chainId: 5318007,
    rpcUrl: "https://lasna-rpc.rnk.dev/",
    explorer: "https://lasna.reactscan.net",
    systemContract: "0x8888888888888888888888888888888888888888" as `0x${string}`,
    cadence: "~1.0s CometBFT",
  },
  unichainSepolia: {
    name: "Unichain Sepolia",
    shortName: "Unichain",
    chainId: 1301,
    rpcUrl: "https://sepolia.unichain.org",
    explorer: "https://sepolia.uniscan.xyz",
    callbackProxy: "0x775c9B990ADe401060B78D0e98684eEf8d2466C1" as `0x${string}`,
    cadence: "1.0s Flashblocks",
  },
} as const;

export const DEPLOYED_CONTRACTS = {
  deployer: "0x06ECf94D9baAFB70daE7A499135e35D1156d4c03" as `0x${string}`,
  neuralSigner: "0x06ECf94D9baAFB70daE7A499135e35D1156d4c03" as `0x${string}`,
  baseMarketFeed: "0xd30a3c3ddc662812b5bd37ca2cbc7b722a2a0f80" as `0x${string}`,
  baseMarketFeedTx: "0x2a2f09da274a30772c8e182a6146cdba8fc2226fc9e591c295cffacde38b7df9" as `0x${string}`,
  unichainMarketFeed: "0xd30a3c3ddc662812b5bd37ca2cbc7b722a2a0f80" as `0x${string}`,
  unichainMarketFeedTx: "0x7c8d8e65d6d5526bd6ba6a5f222fb31ebd3d06c77ec3105a7be5b0a123b18345" as `0x${string}`,
  reactiveGuard: "0xb04fa6fa2eda6f378c0eefdd78eb625d2b4f5ef6" as `0x${string}`,
  reactiveGuardTx: "0x7eeeaeefaa31ce90ea9988419babd8456d2ff488d00be36303ba1f20024c471d" as `0x${string}`,
  baseGuardVault: "0x5b1066a69297e2ec1d1e46374184669568d3380c" as `0x${string}`,
  baseGuardVaultTx: "0x1d8e2c2514fe57b6fa7e6058cef87338c1f2736b3638bcb8d329e31082d4439e" as `0x${string}`,
  unichainGuardVault: "0x5b1066a69297e2ec1d1e46374184669568d3380c" as `0x${string}`,
  unichainGuardVaultTx: "0xec51c6a6f610b00a323132dd5d6ca2804059ec67a148df345229f48853250f84" as `0x${string}`,
} as const;

export const PROJECT_LINKS = {
  repo: "https://github.com/alphonshhhomenicmtu/omniguard-ai",
  youtube: "https://youtu.be/pggBrUXMLTo",
  pitchDeck: "https://github.com/alphonshhhomenicmtu/omniguard-ai/blob/main/docs/omniguard-deck.pdf",
  dorahacks: "https://dorahacks.io/build/51789",
  pages: "https://alphonshhhomenicmtu.github.io/omniguard-ai/",
} as const;

export const VERIFIED_ONCHAIN_LOOPS: VerifiedLoopProof[] = [
  {
    id: "loop-1",
    name: "Loop #1: Stop-Loss Hedge (Rule #1, -6.00% Flash Crash -> 50% Hedge)",
    ruleId: 1,
    actionType: "HEDGE_TO_STABLE",
    appliedBps: 5000,
    originChain: "Base Sepolia (84532)",
    originTxHash: "0x1155b750cbe38ef1ede5727ef1819f7b8fd50625366c836a887e555a83243dd2",
    originBlock: 62980986,
    originTimestamp: 1795518066,
    reactiveTxHash: "0x34598c2fb358b08bfb9ea5e6213f9377c33226db193fd29f4f0a0559355d2e9f",
    reactiveBlock: 9131928,
    callbackTxHash: "0xcb2cb194a1c4a561e911e253832021d8a9c3e8b6be3de9a87090f7e7fb8b1f4c",
    callbackBlock: 68665640,
    callbackTimestamp: 1795518068,
    receiptId: 0,
    onChainLatencySec: 2,
    wallClockMsNote: "7,155 ms full script wall-clock (includes RPC broadcast + 1s polling)",
  },
  {
    id: "loop-2",
    name: "Loop #2: Closed-Loop EIP-712 Neural Circuit Breaker (Rule #3, 91.2% Risk -> 65% Shift)",
    ruleId: 3,
    actionType: "CIRCUIT_BREAKER_PAUSE",
    appliedBps: 6500,
    aiRiskScoreBps: 9120,
    originChain: "Base Sepolia (84532)",
    originTxHash: "0xb11c83b3b5893ab11209c8f2fb0efd62c3f25bc3d7e2585737cd360e288b7f37",
    originTimestamp: 1795518068,
    reactiveTxHash: "0xdb6d3164304d8e7c24e92803bd36e0e0c3b70e3e0b443c1e4113adc97f21c428",
    reactiveBlock: 9131931,
    callbackTxHash: "0x60a450775431b9f27b2065b138cc6cfd737642ad31b16b3f92efd1e9ba7783c2",
    callbackBlock: 68665643,
    callbackTimestamp: 1795518071,
    receiptId: 1,
    onChainLatencySec: 3,
  },
];

export const WALL_CLOCK_PROOF_TELEMETRY = {
  recordedAtIso: "2026-11-24T11:01:14.173Z",
  loop1BlockDeltaSec: 2,
  loop2BlockDeltaSec: 3,
  measuredWallClockEndToEndMs: 7155,
  legacyModeledBaselineMs: 9100,
  explanation:
    "On-chain latency (2s / 3s) measures exact Unix block.timestamp delta between Base Sepolia origin confirmation and Unichain Sepolia callback execution. Wall-clock telemetry (7,155 ms) measures total end-to-end script polling time across RPC confirmation, Lasna relay, and destination log pickup.",
} as const;
