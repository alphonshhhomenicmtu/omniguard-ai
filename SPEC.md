# Reactive Omni Buildathon — Verified Technical & Competition Specification

**Last Verified:** 2026-11-24 (directly verified against DoraHacks live pages, `dev.reactive.network`, `Reactive-Network/reactive-lib-omni`, `Reactive-Network/system-smart-contracts`, and live JSON-RPC queries across Lasna, Base Sepolia, and Unichain Sepolia).

---

## 1. Competition Overview

- **Event:** DoraHacks — *Reactive Omni Buildathon*
- **URL:** `https://dorahacks.io/hackathon/reactive-omni-buildathon/detail`
- **Schedule:**
  - Submission Opens: `2026-11-05 12:00 UTC` (`2026-11-05 20:00 UTC+8`)
  - Submission Deadline: `2026-12-05 20:00 UTC` (`2026-12-06 04:00 UTC+8`)
- **Total Prize Pool:** `$5,500 USD` (denominated in USD, paid in `REACT`)
- **Format:** Virtual, 100% open-source public repository, 100% testnet-compatible

### Tracks & Prizes

| Track | Prizes (USD in REACT) | Brief & Network Requirements |
|---|---|---|
| **Every Second Counts** | 1st: `$2,000` / Runner-up: `$250` | Low-latency DeFi on **Unichain Sepolia** (1s blocks) and/or **Base Sepolia** (200ms blocks since Denim upgrade) via **Reactive Lasna** (~1s CometBFT instant finality). Requires measured full-loop latency numbers (`origin -> Reactive -> callback`) proving why Reactive Omni is needed. |
| **Set It and Forget It** | 1st: `$2,000` / Runner-up: `$250` | Practical personal automations on any Reactive-supported chain. Focuses on real utility, a tool a user would actually keep running, clear personal purpose, and creative event-driven logic. |
| **Reactive Meets AI** | 1st: `$1,000` | Neural networks and reactive contracts working together. **Strict Rule:** The AI must be part of the **running system** (e.g., interpreting events, deciding what a reactive contract does next, or triggered by on-chain events) — NOT merely a coding assistant used during development. |

### Judging Criteria (1–5 Scale, 4 Equally Weighted Criteria)

1. **Execution (Gatekeeper):** Does it run? Must demonstrate real reactive transactions and the callbacks they trigger on-chain. *Entries without live/verifiable reactive transactions and callbacks are not scored further.*
2. **Integration:** Does the reactive contract perform genuine autonomous work rather than being bolted on?
3. **Usefulness:** Does it solve a real problem for users?
4. **Craft:** Clean, readable code, working demo, and clear documentation another developer can follow.

### Mandatory Submission Deliverables

1. Public, open-source repository link (built during the buildathon; prior work allowed only as dependencies).
2. Deployed contract addresses across origin, Reactive Lasna, and destination chain(s).
3. Verifiable transaction hashes demonstrating the full loop: **Origin Event Tx -> Reactive Lasna `react()` Tx -> Destination Callback Tx**.
4. Working demo video **under 3 minutes**.

### Critical Ground Rules

- **Base Sepolia 200ms Block Rule:** Base Sepolia produces blocks every **200ms** (Denim upgrade). All timers, cooldowns, windows, and deadlines MUST use **`block.timestamp` (seconds)** — NEVER `block.number` counts (which would run ~10x faster than expected).
- **Testnet / Mainnet Isolation:** Never mix mainnet and testnet origins/destinations.

---

## 2. Verified Reactive Omni Testnet Network Parameters

> **CRITICAL ARCHITECTURE DISTINCTION (Omni vs. Legacy):**
> Reactive Omni (CometBFT ~1s finality) uses **`reactive-lib-omni`** and ERC-1967 proxied system & callback contracts. Legacy addresses (`0x000...fffFfF` for subscriptions, `0xa6eA49...` on Base Sepolia, `0x929947...` on Unichain Sepolia) belong to pre-Omni legacy docs and MUST NOT be used for new Omni CallbackProxy bindings.

### Live RPC-Verified Testnet Registry

| Network | Role | Chain ID | Hex Chain ID | Official RPC | Omni System / Callback Proxy | Live Code Verified | Live Fee Params (`coeff / extraGas / maxChargeGas`) |
|---|---|---|---|---|---|---|---|
| **Reactive Lasna** | Reactive Layer | `5318007` | `0x512577` | `https://lasna-rpc.rnk.dev/` | `0x8888888888888888888888888888888888888888` | Yes (ERC-1967 proxy) | `1000` / `100,000` / `50,000` |
| **Base Sepolia** | Origin & Destination (200ms blocks) | `84532` | `0x14a34` | `https://sepolia.base.org` | `0x476F44b11F5C942c58f4c8E3d0300E5710743585` | Yes (438-byte ERC-1967 proxy) | `1100` / `80,000` / `50,000` |
| **Unichain Sepolia** | Origin & Destination (1s blocks) | `1301` | `0x515` | `https://sepolia.unichain.org` | `0x775c9B990ADe401060B78D0e98684eEf8d2466C1` | Yes (438-byte ERC-1967 proxy) | `1100` / `80,000` / `50,000` |
| **Ethereum Sepolia** | Origin & Destination | `11155111` | `0xaa36a7` | `https://ethereum-sepolia-rpc.publicnode.com` | `0xAa14d9Cd0f788Ca23d11805986C1d8bd035D23b4` | Yes (438-byte ERC-1967 proxy) | — |

- **Reactive Lasna Block Explorer:** `https://lasna.reactscan.net/`
- **Base Sepolia Block Explorer:** `https://sepolia.basescan.org/`
- **Unichain Sepolia Block Explorer:** `https://sepolia.uniscan.xyz/`
- **Legacy System Contract (CRON source ONLY on Lasna):** `0x0000000000000000000000000000000000fffFfF`
  - `CRON1_TOPIC_0` = `0xf02d6ea5c22a71cffe930a4523fcb4f129be6c804db50e4202fb4e0b07ccb514`
  - `CRON10_TOPIC_0` = `0x04463f7c1651e6b9774d7f85c85bb94654e3c46ca79b0c16fb16d4183307b687`
  - `CRON100_TOPIC_0` = `0xb49937fb8970e19fd46d48f7e3fb00d659deac0347f79cd7cb542f0fc1503c70`
  - `CRON1000_TOPIC_0` = `0xe20b31294d84c3661ddc8f423abb9c70310d0cf172aa2714ead78029b325e3f4`
  - `CRON10000_TOPIC_0` = `0xd214e1d84db704ed42d37f538ea9bf71e44ba28bc1cc088b2f5deca654677a56`

### Official Testnet Faucets (`1 SepETH -> 100 lREACT`, Max `5 ETH` per tx)

- **Base Sepolia Faucet Contract:** `0x2afaFD298b23b62760711756088F75B7409f5967`
- **Ethereum Sepolia Faucet Contract:** `0x9b9BB25f1A81078C544C829c5EB7822d747Cf434`
- **CLI Claim Command:**
  ```bash
  cast send 0x2afaFD298b23b62760711756088F75B7409f5967 \
    --rpc-url https://sepolia.base.org \
    --private-key "$DEPLOYER_PRIVATE_KEY" \
    "request(address)" "$WALLET_ADDR" \
    --value 0.1ether
  ```

---

## 3. Verified Reactive Omni Smart Contract API (`reactive-lib-omni`)

Source: `https://github.com/Reactive-Network/reactive-lib-omni` (`pragma solidity ^0.8.29`)

### Reactive Contract Rules (`AbstractReactive`)
1. Inherit `AbstractReactive` (inherits `AbstractPayer` + `IReactive`).
2. `SYSTEM` constant is hardcoded to `ISystemContract(payable(0x8888888888888888888888888888888888888888))`.
3. `REACTIVE_IGNORE` wildcard constant is `0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad`.
4. **No `vm` / `vmOnly` split:** Omni executes `react(LogRecord calldata log_)` directly on Reactive Network, guarded by `onlySystem` (`msg.sender == address(SYSTEM)`).
5. **Subscriptions:** Call `SYSTEM.subscribe(chainId, contractAddr, topic0, topic1, topic2, topic3)` and `SYSTEM.unsubscribe(...)` from constructor or methods (at least one non-wildcard criterion required).
6. **Callbacks:** Call `SYSTEM.requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0({ chainId, recipient, gasLimit, payload }))`.
   - **First Payload Argument Rule:** Reserve the first argument of the target function as `address` and pass `address(0)` as a placeholder. Reactive Network overwrites the first 160 bits with the requesting reactive contract's address for authentication.
7. **Error Discipline:** Non-matching logs inside `react()` MUST return cleanly (never revert as a filter — reverts emit `ReactiveContractReverted` and still burn gas).
8. **Gas Limits:**
   - Reactive tx gas cap: `900,000` gas.
   - Minimum callback gas limit: `100,000` gas.
   - Destination CallbackProxy deducts `_extraGas (80,000) + _maxChargeGas (50,000) + failureEventGas` before forwarding gas to the recipient. Recommended callback `gasLimit`: **`450,000` – `600,000`**.
9. **Funding & Debt:** Any `debt > 0` stops execution (`InDebt`). Fund reactive contracts in `lREACT` via `payable` constructor / `depositTo(address)` on `SYSTEM` / direct transfer + `coverDebt()`.

### Callback Contract Rules (`AbstractCallback`)
1. Inherit `AbstractCallback(IPayable callbackProxy_, address callbackSender_)`. Both `_SERVICE_PROVIDER` and `_CALLBACK_SENDER` are `immutable`.
2. Guard every callback entrypoint with **BOTH** modifiers:
   - `onlyServiceProvider` (proves `msg.sender == CallbackProxy`)
   - `onlyCallbackSender(reactiveSender_)` (proves injected first argument equals the authorized Reactive Contract on Lasna)
3. **Mandatory Deployment Order:**
   1. Deploy Origin contract(s) on Base Sepolia (and optional Unichain Sepolia).
   2. Deploy `OmniGuardReactive` on Reactive Lasna (funded with `lREACT`).
   3. Deploy `OmniGuardVault` on Destination chain(s) (Base Sepolia and/or Unichain Sepolia), passing `(CALLBACK_PROXY, OMNI_GUARD_REACTIVE_ADDRESS)` and funding with destination native `ETH`.
   4. Register destination vault(s) & guard rules on `OmniGuardReactive` via owner setter (`registerRule(...)`), and optionally call `depositTo(vault)` on each destination `CallbackProxy`.

### RNK Custom JSON-RPC Methods (Lasna Verification & Telemetry)
- `rnk_getFilters` — verify active subscriptions on Lasna
- `rnk_getCallBackLogs` — inspect callback logs emitted in a Reactive block
- `rnk_getBlockSequences` / `rnk_getCommittedSequenceFrontier` — inspect CometBFT committed reactive sequences
- `SYSTEM.getCallbacks(uint256 rvmTxHash)` — inspect validator-recorded destination callback tx hashes and error bytes

---

## 4. OmniGuard AI — Track Alignment Matrix

| Buildathon Track | How OmniGuard AI Wins This Track |
|---|---|
| **Every Second Counts** (`$2,000`) | Sub-second cross-chain protection loop between **Base Sepolia (200ms)** -> **Reactive Lasna (~1s CometBFT)** -> **Unichain Sepolia (1s)** & **Base Sepolia (200ms)**. Strict `block.timestamp`-only cooldowns & deadlines. On-chain & off-chain end-to-end latency instrumentation comparing Reactive Omni (~2–3s) vs. Legacy Reactive (~9–12s). |
| **Set It and Forget It** (`$2,000`) | Natural-language personal automation studio: users describe plain-English guardrails ("Auto-hedge 40% of my WETH vault if price drops >3.5% or health factor <1.25x with 30s cooldown"), compile to on-chain `GuardRule` parameters, register once, and let `OmniGuardReactive` protect vaults 24/7 with zero polling or manual intervention. |
| **Reactive Meets AI** (`$1,000`) | **Live Neural Network IN the running loop:** A calibrated 2-layer MLP Neural Risk Engine runs continuously on live on-chain event streams (`PriceUpdated`, `HealthFactorAlert`, `ReactionDispatched`), classifies market regimes (`CALM`, `ELEVATED`, `VOLATILE`, `CASCADE_CRITICAL`), signs EIP-712 `NeuralRegimeAdvisement` attestations verified on-chain via `ecrecover` in `OmniMarketFeed`, and triggers `OmniGuardReactive` to dynamically tighten protection thresholds and execute preemptive cross-chain hedges. |
