# OmniGuard AI — 2m 30s DoraHacks Demo Video Script

**Target Duration:** `2:25` (comfortably under the 3-minute DoraHacks limit)  
**Resolution:** `1920x1080` screen recording (terminal + live dashboard + block explorers)

---

## 0:00 – 0:25 | The Problem & Why Reactive Omni (~1s CometBFT)
- **Visual:** Open OmniGuard AI Dashboard (`http://127.0.0.1:5178`) showing live Base Sepolia (`84532`), Reactive Lasna (`5318007`), and Unichain Sepolia (`1301`) block heights ticking in real time.
- **Narration:**
  > "DeFi vaults on fast L2s like Base Sepolia — producing blocks every 200 milliseconds — and Unichain Sepolia — producing 1-second blocks — can get liquidated in under four seconds during a flash crash. On legacy 7-second reactive blocks, cross-chain stop-loss arrived too late. OmniGuard AI uses **Reactive Omni's ~1-second CometBFT finality** plus a **live neural risk network in the loop** to protect vaults across chains in ~2.2 seconds."

## 0:25 – 0:55 | Set It and Forget It — Natural-Language Rule Studio
- **Visual:** Click **"200ms Block Warning Test"** preset in the Natural-Language Rule Studio -> click **Compile & Preview Calldata** -> highlight the automatic warning banner converting `"15 blocks"` into `30s Unix timestamp cooldown` + generated `OmniGuardReactive.createRule()` ABI calldata -> click **Activate Guard Rule**.
- **Narration:**
  > "Anyone can author autonomous protection rules in plain English — no Solidity required. Notice what happens if a user accidentally specifies a block-count cooldown: because Base Sepolia runs at 200ms blocks, our compiler automatically converts it into a strict Unix timestamp cooldown and generates exact `createRule()` calldata for Reactive Lasna with a 500,000 callback gas budget that safely clears Omni CallbackProxy's 130,000 gas overhead."

## 0:55 – 1:40 | Every Second Counts + Reactive Meets AI — Live Cross-Chain Loop
- **Visual:** Click **"Flash Crash (-6.2% WETH)"** then **"Neural Cascade Escalation"** in the Trigger Deck. Point to:
  1. The 3-hop pipeline (`Base Sepolia 210ms -> Reactive Lasna 1,040ms -> Unichain Sepolia 1,020ms = 2.27s`, **~4.2x faster** than legacy Reactive).
  2. The **OmniRisk-MLP-7x12x4** panel shifting from `CALM` to `CASCADE_CRITICAL`, displaying feature attributions and the live **EIP-712 signature** verified on-chain via `ecrecover` inside `OmniMarketFeed.sol`.
  3. The destination `OmniGuardVault` portfolio bar automatically shifting volatile WETH exposure into USDC safe reserve and activating the circuit breaker.
- **Narration:**
  > "This isn't AI that only wrote the code — our calibrated 7-by-12-by-4 neural network runs live in the loop. When Base Sepolia emits a flash crash, the neural sentinel classifies the cascade regime, signs an EIP-712 advisement verified on-chain, and Reactive Lasna tightens drawdown thresholds by 35% while dispatching a `requestCallbackV_1_0` callback straight to Unichain Sepolia's official Omni CallbackProxy."

## 1:40 – 2:15 | On-Chain Testnet Proof & Foundry Verification
- **Visual:** Split screen showing:
  - Terminal running `cd contracts && forge test -vv` (**18/18 tests passing**, highlighting `test_TimestampCooldownInvariant_Under200msBaseBlocks` and `test_NeuralRegime_AdaptiveThresholdTightening`).
  - Terminal showing `npm run demo:trigger` output + clicking through the 3 live testnet transaction hashes on BaseScan Sepolia, Lasna Reactscan, and Uniscan Sepolia.
- **Narration:**
  > "Under the hood, our contracts inherit `reactive-lib-omni`'s `AbstractReactive` and `AbstractCallback`, verified by 18 Foundry unit, security, fuzz, and 200ms timestamp invariant tests — all passing. Here are the live testnet transaction hashes proving the full loop from Base Sepolia origin event, through Reactive Lasna's `react()`, to destination settlement on Unichain Sepolia."

## 2:15 – 2:28 | Wrap-Up
- **Visual:** Return to OmniGuard AI Dashboard showing the chronological Origin &rarr; Reactive &rarr; Callback Audit Trail and GitHub repo URL.
- **Narration:**
  > "OmniGuard AI brings sub-3-second cross-chain protection, natural-language personal automation, and live neural risk inference together on Reactive Omni. Clone the open-source repo and deploy end-to-end in four commands. Thank you!"
