// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import { Test, Vm } from "forge-std/Test.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { AbstractPayer } from "@reactive/src/base/AbstractPayer.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";

import { OmniGuardTypes } from "../src/interfaces/IOmniGuardTypes.sol";
import { OmniMarketFeed } from "../src/origin/OmniMarketFeed.sol";
import { OmniGuardReactive } from "../src/reactive/OmniGuardReactive.sol";
import { OmniGuardVault } from "../src/destination/OmniGuardVault.sol";
import { MockOmniSystem } from "./mocks/MockOmniSystem.sol";
import { MockOmniCallbackProxy } from "./mocks/MockOmniCallbackProxy.sol";

/**
 * @title OmniGuardEndToEndTest
 * @notice Full unit, V2 security regression, Base Sepolia 200ms timestamp invariant, fuzz, and cross-chain
 *         Origin -> Reactive Lasna -> Destination Callback integration test suite.
 */
contract OmniGuardEndToEndTest is Test {
    address internal constant SYSTEM_ADDR = 0x8888888888888888888888888888888888888888;
    address internal constant LEGACY_SYSTEM_ADDR = 0x0000000000000000000000000000000000fffFfF;

    uint256 internal constant BASE_SEPOLIA_CHAIN_ID = 84532;
    uint256 internal constant UNICHAIN_SEPOLIA_CHAIN_ID = 1301;
    uint256 internal constant LASNA_CHAIN_ID = 5318007;

    uint256 internal constant INITIAL_WETH_PRICE_E8 = 3200_00000000; // $3,200.00
    uint256 internal constant NEURAL_SIGNER_PK = 0xA11CE001;
    uint256 internal constant NEW_NEURAL_SIGNER_PK = 0xA11CE002;

    address internal owner = makeAddr("owner");
    address internal operator = makeAddr("operator");
    address internal user = makeAddr("user");
    address internal attacker = makeAddr("attacker");
    address internal neuralSigner;

    MockOmniSystem internal system;
    MockOmniCallbackProxy internal baseProxy;
    MockOmniCallbackProxy internal unichainProxy;

    OmniMarketFeed internal baseFeed;
    OmniMarketFeed internal unichainFeed;
    OmniGuardReactive internal reactiveGuard;
    OmniGuardVault internal baseVault;
    OmniGuardVault internal unichainVault;

    uint256 internal txHashCounter = 1000;

    function setUp() public {
        vm.warp(1_795_500_000);
        vm.roll(62_831_270);

        neuralSigner = vm.addr(NEURAL_SIGNER_PK);

        // Etch MockOmniSystem at the exact Reactive Omni SYSTEM address (0x8888...8888).
        MockOmniSystem systemImpl = new MockOmniSystem();
        vm.etch(SYSTEM_ADDR, address(systemImpl).code);
        system = MockOmniSystem(payable(SYSTEM_ADDR));

        // Deploy destination Omni CallbackProxy mocks for Base Sepolia and Unichain Sepolia.
        baseProxy = new MockOmniCallbackProxy();
        unichainProxy = new MockOmniCallbackProxy();

        vm.deal(owner, 100 ether);
        vm.deal(user, 10 ether);
        vm.deal(attacker, 10 ether);

        vm.startPrank(owner);
        // Step 1: Deploy Origin Market Feeds on Base Sepolia (primary) and Unichain Sepolia (secondary).
        baseFeed = new OmniMarketFeed(owner, neuralSigner, INITIAL_WETH_PRICE_E8);
        unichainFeed = new OmniMarketFeed(owner, neuralSigner, INITIAL_WETH_PRICE_E8);

        // Step 2: Deploy OmniGuardReactive on Reactive Lasna (funded with lREACT).
        reactiveGuard = new OmniGuardReactive{ value: 1 ether }(BASE_SEPOLIA_CHAIN_ID, address(baseFeed), owner);

        // Step 3: Deploy destination OmniGuardVaults bound to Reactive Omni CallbackProxies & reactiveGuard.
        baseVault =
            new OmniGuardVault{ value: 0.5 ether }(IPayable(payable(address(baseProxy))), address(reactiveGuard), owner);
        unichainVault = new OmniGuardVault{ value: 0.5 ether }(
            IPayable(payable(address(unichainProxy))), address(reactiveGuard), owner
        );

        // Step 4 (V2): Allowlist destination vaults and pin trusted neural signer.
        reactiveGuard.setAllowedDestinationVault(BASE_SEPOLIA_CHAIN_ID, address(baseVault), true);
        reactiveGuard.setAllowedDestinationVault(UNICHAIN_SEPOLIA_CHAIN_ID, address(unichainVault), true);
        reactiveGuard.setTrustedNeuralSigner(neuralSigner);
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------
    // Helper: Convert recorded Vm.Log to IReactive.LogRecord and replay full loop
    // -------------------------------------------------------------------------
    function _relayRecordedLogs(
        Vm.Log[] memory logs_,
        uint256 originChainId_,
        uint64 simulatedLatencySec_,
        uint256 reactiveFee_,
        uint256 callbackFee_
    ) internal returns (uint256 callbacksDelivered) {
        system.clearCallbacks();
        uint256 syntheticTxHash = uint256(keccak256(abi.encodePacked("tx", ++txHashCounter, block.timestamp)));

        for (uint256 i = 0; i < logs_.length; ++i) {
            Vm.Log memory entry = logs_[i];
            if (entry.topics.length == 0) continue;

            uint256 t0 = uint256(entry.topics[0]);
            bool isWatchedTopic = t0 == OmniGuardTypes.PRICE_UPDATED_TOPIC0
                || t0 == OmniGuardTypes.HEALTH_FACTOR_ALERT_TOPIC0
                || t0 == OmniGuardTypes.NEURAL_REGIME_COMMITTED_TOPIC0;
            if (!isWatchedTopic) continue;

            IReactive.LogRecord memory rec = IReactive.LogRecord({
                chainId: originChainId_,
                contractAddress: entry.emitter,
                topic0: t0,
                topic1: entry.topics.length > 1 ? uint256(entry.topics[1]) : 0,
                topic2: entry.topics.length > 2 ? uint256(entry.topics[2]) : 0,
                topic3: entry.topics.length > 3 ? uint256(entry.topics[3]) : 0,
                data: entry.data,
                blockNumber: block.number,
                opCode: entry.topics.length,
                blockHash: uint256(blockhash(block.number > 0 ? block.number - 1 : 0)),
                txHash: syntheticTxHash,
                logIndex: i
            });

            bool ok = system.trigger(IReactive(payable(address(reactiveGuard))), rec, reactiveFee_);
            assertTrue(ok, "react() should not revert");
        }

        if (simulatedLatencySec_ > 0) {
            vm.warp(block.timestamp + simulatedLatencySec_);
        }

        uint256 count = system.callbackCount();
        for (uint256 c = 0; c < count; ++c) {
            MockOmniSystem.RecordedCallback memory cb = system.getCallback(c);
            MockOmniCallbackProxy proxy =
                cb.config.chainId == UNICHAIN_SEPOLIA_CHAIN_ID ? unichainProxy : baseProxy;
            (bool ok,) = proxy.deliverCallback(cb.sender, cb.config, callbackFee_);
            assertTrue(ok, "destination callback should succeed");
            callbacksDelivered++;
        }
    }

    function _signAdvisement(OmniMarketFeed.NeuralAdvisement memory adv_, uint256 signerPk_)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = baseFeed.hashNeuralAdvisement(adv_);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk_, digest);
        return abi.encodePacked(r, s, v);
    }

    function _defaultStopLossRuleParams(address destVault_, uint256 destChainId_)
        internal
        pure
        returns (OmniGuardTypes.CreateRuleParams memory)
    {
        return OmniGuardTypes.CreateRuleParams({
            marketId: OmniGuardTypes.MARKET_WETH_USDC,
            monitoredVault: address(0),
            destinationChainId: destChainId_,
            destinationVault: destVault_,
            kind: OmniGuardTypes.RuleKind.STOP_LOSS_HEDGE,
            actionType: OmniGuardTypes.ActionType.HEDGE_TO_STABLE,
            priceFloorE8: 3050_00000000,
            maxDrawdownBps: 400,
            minHealthFactorBps: 0,
            aiRiskThresholdBps: 0,
            spreadThresholdBps: 0,
            hedgeBps: 5000,
            cooldownSeconds: 30,
            expiresAt: 0,
            callbackGasLimit: 500_000,
            adaptiveAiEnabled: true
        });
    }

    // -------------------------------------------------------------------------
    // 1. Canonical Selectors & Constructor Subscriptions
    // -------------------------------------------------------------------------
    function test_CanonicalTopic0SelectorsMatchEvents() public pure {
        assertEq(uint256(OmniMarketFeed.PriceUpdated.selector), OmniGuardTypes.PRICE_UPDATED_TOPIC0);
        assertEq(uint256(OmniMarketFeed.HealthFactorAlert.selector), OmniGuardTypes.HEALTH_FACTOR_ALERT_TOPIC0);
        assertEq(
            uint256(OmniMarketFeed.NeuralRegimeCommitted.selector), OmniGuardTypes.NEURAL_REGIME_COMMITTED_TOPIC0
        );
    }

    function test_ConstructorSubscribesToAllThreePrimaryOriginTopics() public view {
        assertEq(system.subscriptionCount(), 3);

        (address sub0, uint256 c0, address addr0, uint256 t0,,,, bool a0) = system.subscriptions(0);
        assertEq(sub0, address(reactiveGuard));
        assertEq(c0, BASE_SEPOLIA_CHAIN_ID);
        assertEq(addr0, address(baseFeed));
        assertEq(t0, OmniGuardTypes.PRICE_UPDATED_TOPIC0);
        assertTrue(a0);

        (,,, uint256 t1,,,, bool a1) = system.subscriptions(1);
        assertEq(t1, OmniGuardTypes.HEALTH_FACTOR_ALERT_TOPIC0);
        assertTrue(a1);

        (,,, uint256 t2,,,, bool a2) = system.subscriptions(2);
        assertEq(t2, OmniGuardTypes.NEURAL_REGIME_COMMITTED_TOPIC0);
        assertTrue(a2);
    }

    // -------------------------------------------------------------------------
    // 2. Full End-to-End Loop: Stop-Loss Flash Crash (Base Sepolia -> Lasna -> Unichain Sepolia)
    // -------------------------------------------------------------------------
    function test_FullLoop_StopLossFlashCrash_BaseToUnichain() public {
        vm.prank(owner);
        uint256 ruleId = reactiveGuard.createRule(_defaultStopLossRuleParams(address(unichainVault), UNICHAIN_SEPOLIA_CHAIN_ID));

        vm.recordLogs();
        vm.prank(owner);
        uint256 crashedPrice = baseFeed.simulateFlashCrash(OmniGuardTypes.MARKET_WETH_USDC, 600, 820);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(crashedPrice, 3008_00000000);

        uint256 delivered = _relayRecordedLogs(logs, BASE_SEPOLIA_CHAIN_ID, 2, 0.001 ether, 0.0005 ether);
        assertEq(delivered, 1);

        OmniGuardVault.VaultPosition memory pos = unichainVault.getPosition(OmniGuardTypes.MARKET_WETH_USDC);
        assertEq(pos.volatileCollateralUsdE8, 50_000_00000000, "50% volatile collateral hedged");
        assertEq(pos.stableReserveUsdE8, 75_000_00000000, "stable reserve increased by $50k");

        assertEq(unichainVault.getReceiptsCount(), 1);
        OmniGuardVault.ExecutionReceipt memory receipt = unichainVault.getReceipt(0);
        assertEq(receipt.ruleId, ruleId);
        assertEq(receipt.endToEndLatencySec, 2);
        assertEq(receipt.appliedBps, 5000);
        assertEq(reactiveGuard.totalCallbacksRequested(), 1);
    }

    // -------------------------------------------------------------------------
    // 3. Full End-to-End Loop: Health Factor Liquidation Rescue
    // -------------------------------------------------------------------------
    function test_FullLoop_HealthFactorRescue_DeleveragesDebt() public {
        vm.prank(owner);
        reactiveGuard.createRule(
            OmniGuardTypes.CreateRuleParams({
                marketId: OmniGuardTypes.MARKET_WETH_USDC,
                monitoredVault: address(baseVault),
                destinationChainId: BASE_SEPOLIA_CHAIN_ID,
                destinationVault: address(baseVault),
                kind: OmniGuardTypes.RuleKind.HEALTH_FACTOR_RESCUE,
                actionType: OmniGuardTypes.ActionType.DELEVERAGE_COLLATERAL,
                priceFloorE8: 0,
                maxDrawdownBps: 0,
                minHealthFactorBps: 12_500,
                aiRiskThresholdBps: 0,
                spreadThresholdBps: 0,
                hedgeBps: 4000,
                cooldownSeconds: 60,
                expiresAt: 0,
                callbackGasLimit: 500_000,
                adaptiveAiEnabled: true
            })
        );

        uint256 hfBefore = baseVault.getHealthFactorBps(OmniGuardTypes.MARKET_WETH_USDC);

        vm.recordLogs();
        vm.prank(owner);
        baseFeed.reportHealthFactor(address(baseVault), user, 11_800, 82_000_00000000, 60_000_00000000);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 delivered = _relayRecordedLogs(logs, BASE_SEPOLIA_CHAIN_ID, 2, 0.001 ether, 0.0005 ether);
        assertEq(delivered, 1);

        OmniGuardVault.VaultPosition memory pos = baseVault.getPosition(OmniGuardTypes.MARKET_WETH_USDC);
        assertEq(pos.debtUsdE8, 36_000_00000000);
        assertEq(pos.stableReserveUsdE8, 1_000_00000000);

        uint256 hfAfter = baseVault.getHealthFactorBps(OmniGuardTypes.MARKET_WETH_USDC);
        assertGt(hfAfter, hfBefore, "health factor improved after deleveraging");
    }

    // -------------------------------------------------------------------------
    // 4. Reactive Meets AI: Live EIP-712 Neural Escalation & Adaptive Threshold Tightening
    // -------------------------------------------------------------------------
    function test_FullLoop_NeuralRegime_EIP712Verification_AndEscalation() public {
        vm.prank(owner);
        reactiveGuard.createRule(
            OmniGuardTypes.CreateRuleParams({
                marketId: OmniGuardTypes.MARKET_WETH_USDC,
                monitoredVault: address(0),
                destinationChainId: UNICHAIN_SEPOLIA_CHAIN_ID,
                destinationVault: address(unichainVault),
                kind: OmniGuardTypes.RuleKind.AI_REGIME_ESCALATION,
                actionType: OmniGuardTypes.ActionType.CIRCUIT_BREAKER_PAUSE,
                priceFloorE8: 0,
                maxDrawdownBps: 0,
                minHealthFactorBps: 0,
                aiRiskThresholdBps: 7500,
                spreadThresholdBps: 0,
                hedgeBps: 4000,
                cooldownSeconds: 45,
                expiresAt: 0,
                callbackGasLimit: 500_000,
                adaptiveAiEnabled: true
            })
        );

        OmniMarketFeed.NeuralAdvisement memory adv = OmniMarketFeed.NeuralAdvisement({
            marketId: OmniGuardTypes.MARKET_WETH_USDC,
            regime: uint8(OmniGuardTypes.RiskRegime.CASCADE_CRITICAL),
            riskScoreBps: 8840,
            recommendedHedgeBps: 6500,
            issuedAt: uint64(block.timestamp),
            validUntil: uint64(block.timestamp + 180),
            nonce: 0
        });
        bytes memory sig = _signAdvisement(adv, NEURAL_SIGNER_PK);

        vm.recordLogs();
        vm.prank(user);
        baseFeed.submitSignedNeuralRegime(adv, sig);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 delivered = _relayRecordedLogs(logs, BASE_SEPOLIA_CHAIN_ID, 2, 0.001 ether, 0.0005 ether);
        assertEq(delivered, 1);

        OmniGuardVault.VaultPosition memory pos = unichainVault.getPosition(OmniGuardTypes.MARKET_WETH_USDC);
        assertTrue(pos.circuitBreakerActive, "circuit breaker activated by neural escalation");
        assertEq(pos.volatileCollateralUsdE8, 35_000_00000000, "65% emergency hedge applied from neural recommendation");
        assertEq(pos.stableReserveUsdE8, 90_000_00000000);
        assertEq(reactiveGuard.totalNeuralUpdates(), 1);
    }

    function test_NeuralRegime_AdaptiveThresholdTightening() public {
        vm.prank(owner);
        uint256 ruleId = reactiveGuard.createRule(
            OmniGuardTypes.CreateRuleParams({
                marketId: OmniGuardTypes.MARKET_WETH_USDC,
                monitoredVault: address(0),
                destinationChainId: UNICHAIN_SEPOLIA_CHAIN_ID,
                destinationVault: address(unichainVault),
                kind: OmniGuardTypes.RuleKind.STOP_LOSS_HEDGE,
                actionType: OmniGuardTypes.ActionType.HEDGE_TO_STABLE,
                priceFloorE8: 0,
                maxDrawdownBps: 400,
                minHealthFactorBps: 0,
                aiRiskThresholdBps: 0,
                spreadThresholdBps: 0,
                hedgeBps: 3000,
                cooldownSeconds: 30,
                expiresAt: 0,
                callbackGasLimit: 500_000,
                adaptiveAiEnabled: true
            })
        );

        vm.recordLogs();
        vm.prank(owner);
        baseFeed.simulateFlashCrash(OmniGuardTypes.MARKET_WETH_USDC, 300, 220);
        uint256 calmDelivered = _relayRecordedLogs(vm.getRecordedLogs(), BASE_SEPOLIA_CHAIN_ID, 1, 0, 0);
        assertEq(calmDelivered, 0, "3% drop should not fire under CALM 4% threshold");

        OmniMarketFeed.NeuralAdvisement memory adv = OmniMarketFeed.NeuralAdvisement({
            marketId: OmniGuardTypes.MARKET_WETH_USDC,
            regime: uint8(OmniGuardTypes.RiskRegime.CASCADE_CRITICAL),
            riskScoreBps: 9100,
            recommendedHedgeBps: 5000,
            issuedAt: uint64(block.timestamp),
            validUntil: uint64(block.timestamp + 180),
            nonce: 0
        });
        bytes memory sig = _signAdvisement(adv, NEURAL_SIGNER_PK);

        vm.recordLogs();
        baseFeed.submitSignedNeuralRegime(adv, sig);
        _relayRecordedLogs(vm.getRecordedLogs(), BASE_SEPOLIA_CHAIN_ID, 1, 0, 0);

        (uint16 effDrawdown, uint16 activeRisk) =
            reactiveGuard.getEffectiveDrawdownBps(ruleId, uint64(block.timestamp));
        assertEq(effDrawdown, 260);
        assertEq(activeRisk, 9100);

        vm.recordLogs();
        vm.prank(owner);
        baseFeed.simulateFlashCrash(OmniGuardTypes.MARKET_WETH_USDC, 300, 750);
        uint256 criticalDelivered = _relayRecordedLogs(vm.getRecordedLogs(), BASE_SEPOLIA_CHAIN_ID, 2, 0, 0);
        assertEq(criticalDelivered, 1, "3% drop MUST fire under CASCADE_CRITICAL 2.6% tightened threshold");

        OmniGuardVault.ExecutionReceipt memory r = unichainVault.getReceipt(0);
        assertEq(r.appliedBps, 5000, "adaptive hedge boosted from 30% to neural recommended 50%");
        assertEq(r.aiRiskScoreBps, 9100);
    }

    // -------------------------------------------------------------------------
    // 5. Cross-Chain Price Spread Rebalancing (Base Sepolia 200ms vs Unichain Sepolia 1s)
    // -------------------------------------------------------------------------
    function test_FullLoop_CrossChainSpreadRebalance_BaseVsUnichain() public {
        vm.startPrank(owner);
        reactiveGuard.setSecondaryOriginFeed(UNICHAIN_SEPOLIA_CHAIN_ID, address(unichainFeed));
        reactiveGuard.createRule(
            OmniGuardTypes.CreateRuleParams({
                marketId: OmniGuardTypes.MARKET_WETH_USDC,
                monitoredVault: address(0),
                destinationChainId: UNICHAIN_SEPOLIA_CHAIN_ID,
                destinationVault: address(unichainVault),
                kind: OmniGuardTypes.RuleKind.CROSS_CHAIN_REBALANCE,
                actionType: OmniGuardTypes.ActionType.CROSS_CHAIN_REBALANCE,
                priceFloorE8: 0,
                maxDrawdownBps: 0,
                minHealthFactorBps: 0,
                aiRiskThresholdBps: 0,
                spreadThresholdBps: 150,
                hedgeBps: 2500,
                cooldownSeconds: 20,
                expiresAt: 0,
                callbackGasLimit: 500_000,
                adaptiveAiEnabled: false
            })
        );
        vm.stopPrank();

        vm.recordLogs();
        vm.prank(owner);
        baseFeed.postPriceTick(OmniGuardTypes.MARKET_WETH_USDC, 3200_00000000, 140);
        assertEq(_relayRecordedLogs(vm.getRecordedLogs(), BASE_SEPOLIA_CHAIN_ID, 1, 0, 0), 0);

        vm.recordLogs();
        vm.prank(owner);
        unichainFeed.postPriceTick(OmniGuardTypes.MARKET_WETH_USDC, 3100_00000000, 200);
        uint256 delivered = _relayRecordedLogs(vm.getRecordedLogs(), UNICHAIN_SEPOLIA_CHAIN_ID, 2, 0, 0);
        assertEq(delivered, 1);

        OmniGuardVault.VaultPosition memory pos = unichainVault.getPosition(OmniGuardTypes.MARKET_WETH_USDC);
        assertEq(pos.rebalancedVolumeUsdE8, 25_000_00000000);
        assertEq(pos.volatileCollateralUsdE8, 75_000_00000000);
        assertEq(pos.stableReserveUsdE8, 50_000_00000000);
    }

    // -------------------------------------------------------------------------
    // 6. Strict Timestamp Cooldown Under Base Sepolia 200ms Blocks
    // -------------------------------------------------------------------------
    function test_TimestampCooldownInvariant_Under200msBaseBlocks() public {
        vm.prank(owner);
        reactiveGuard.createRule(
            OmniGuardTypes.CreateRuleParams({
                marketId: OmniGuardTypes.MARKET_WETH_USDC,
                monitoredVault: address(0),
                destinationChainId: BASE_SEPOLIA_CHAIN_ID,
                destinationVault: address(baseVault),
                kind: OmniGuardTypes.RuleKind.STOP_LOSS_HEDGE,
                actionType: OmniGuardTypes.ActionType.HEDGE_TO_STABLE,
                priceFloorE8: 0,
                maxDrawdownBps: 300,
                minHealthFactorBps: 0,
                aiRiskThresholdBps: 0,
                spreadThresholdBps: 0,
                hedgeBps: 2000,
                cooldownSeconds: 30,
                expiresAt: 0,
                callbackGasLimit: 500_000,
                adaptiveAiEnabled: false
            })
        );

        vm.recordLogs();
        vm.prank(owner);
        baseFeed.simulateFlashCrash(OmniGuardTypes.MARKET_WETH_USDC, 400, 500);
        assertEq(_relayRecordedLogs(vm.getRecordedLogs(), BASE_SEPOLIA_CHAIN_ID, 0, 0, 0), 1);

        // +50 Base blocks (200ms each), only +10s elapsed (< 30s cooldown)
        vm.roll(block.number + 50);
        vm.warp(block.timestamp + 10);

        vm.recordLogs();
        vm.prank(owner);
        baseFeed.simulateFlashCrash(OmniGuardTypes.MARKET_WETH_USDC, 400, 520);
        assertEq(_relayRecordedLogs(vm.getRecordedLogs(), BASE_SEPOLIA_CHAIN_ID, 0, 0, 0), 0);

        // +100 more blocks, +20s elapsed (30s total) -> fires cleanly
        vm.roll(block.number + 100);
        vm.warp(block.timestamp + 20);

        vm.recordLogs();
        vm.prank(owner);
        baseFeed.simulateFlashCrash(OmniGuardTypes.MARKET_WETH_USDC, 400, 540);
        assertEq(_relayRecordedLogs(vm.getRecordedLogs(), BASE_SEPOLIA_CHAIN_ID, 1, 0, 0), 1);
    }

    function test_ExpiredRuleDoesNotTrigger() public {
        uint64 deadline = uint64(block.timestamp + 60);
        vm.prank(owner);
        reactiveGuard.createRule(
            OmniGuardTypes.CreateRuleParams({
                marketId: OmniGuardTypes.MARKET_WETH_USDC,
                monitoredVault: address(0),
                destinationChainId: BASE_SEPOLIA_CHAIN_ID,
                destinationVault: address(baseVault),
                kind: OmniGuardTypes.RuleKind.STOP_LOSS_HEDGE,
                actionType: OmniGuardTypes.ActionType.HEDGE_TO_STABLE,
                priceFloorE8: 0,
                maxDrawdownBps: 300,
                minHealthFactorBps: 0,
                aiRiskThresholdBps: 0,
                spreadThresholdBps: 0,
                hedgeBps: 2000,
                cooldownSeconds: 10,
                expiresAt: deadline,
                callbackGasLimit: 500_000,
                adaptiveAiEnabled: false
            })
        );

        vm.warp(deadline + 1);
        vm.recordLogs();
        vm.prank(owner);
        baseFeed.simulateFlashCrash(OmniGuardTypes.MARKET_WETH_USDC, 500, 600);
        assertEq(_relayRecordedLogs(vm.getRecordedLogs(), BASE_SEPOLIA_CHAIN_ID, 1, 0, 0), 0);
    }

    // -------------------------------------------------------------------------
    // 7. Base Security, Auth, Replay, CRON & Debt Settlement
    // -------------------------------------------------------------------------
    function test_AuthSecurity_OnlySystemOnReact() public {
        IReactive.LogRecord memory fakeLog = IReactive.LogRecord({
            chainId: BASE_SEPOLIA_CHAIN_ID,
            contractAddress: address(baseFeed),
            topic0: OmniGuardTypes.PRICE_UPDATED_TOPIC0,
            topic1: uint256(OmniGuardTypes.MARKET_WETH_USDC),
            topic2: 0,
            topic3: 0,
            data: "",
            blockNumber: block.number,
            opCode: 2,
            blockHash: 0,
            txHash: 1,
            logIndex: 0
        });

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, attacker, SYSTEM_ADDR));
        reactiveGuard.react(fakeLog);
    }

    function test_AuthSecurity_DualCallbackGuards() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, attacker, address(unichainProxy)));
        unichainVault.executeProtection(
            address(reactiveGuard), 1, 0, OmniGuardTypes.MARKET_WETH_USDC, 3000_00000000, 5000, 0, 100, 1, 0
        );

        bytes memory payload = abi.encodeWithSignature(
            "executeProtection(address,uint256,uint8,bytes32,uint256,uint16,uint16,uint64,uint256,uint256)",
            address(0),
            1,
            uint8(0),
            OmniGuardTypes.MARKET_WETH_USDC,
            uint256(3000_00000000),
            uint16(5000),
            uint16(0),
            uint64(block.timestamp),
            uint256(999),
            uint256(0)
        );
        (bool ok, bytes memory ret) = unichainProxy.deliverCallback(
            attacker,
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: UNICHAIN_SEPOLIA_CHAIN_ID,
                recipient: address(unichainVault),
                gasLimit: 500_000,
                payload: payload
            }),
            0
        );
        assertFalse(ok);
        assertEq(
            ret, abi.encodeWithSelector(AbstractCallback.CallbackNotAuthorized.selector, attacker, address(reactiveGuard))
        );
    }

    function test_EIP712Security_RejectsForgedSignerExpiredAndReplayNonce() public {
        OmniMarketFeed.NeuralAdvisement memory adv = OmniMarketFeed.NeuralAdvisement({
            marketId: OmniGuardTypes.MARKET_WETH_USDC,
            regime: uint8(OmniGuardTypes.RiskRegime.VOLATILE),
            riskScoreBps: 7000,
            recommendedHedgeBps: 4000,
            issuedAt: uint64(block.timestamp),
            validUntil: uint64(block.timestamp + 60),
            nonce: 0
        });

        bytes memory badSig = _signAdvisement(adv, 0xBAD001);
        vm.expectRevert(
            abi.encodeWithSelector(OmniMarketFeed.UnauthorizedNeuralSigner.selector, vm.addr(0xBAD001), neuralSigner)
        );
        baseFeed.submitSignedNeuralRegime(adv, badSig);

        bytes memory goodSig = _signAdvisement(adv, NEURAL_SIGNER_PK);
        baseFeed.submitSignedNeuralRegime(adv, goodSig);

        vm.expectRevert(abi.encodeWithSelector(OmniMarketFeed.InvalidNonce.selector, 1, 0));
        baseFeed.submitSignedNeuralRegime(adv, goodSig);

        adv.nonce = 1;
        adv.validUntil = uint64(block.timestamp - 1);
        bytes memory expiredSig = _signAdvisement(adv, NEURAL_SIGNER_PK);
        vm.expectRevert(
            abi.encodeWithSelector(OmniMarketFeed.ExpiredAdvisement.selector, adv.validUntil, uint64(block.timestamp))
        );
        baseFeed.submitSignedNeuralRegime(adv, expiredSig);
    }

    function test_ReplayProtection_DuplicateOriginTxBlocked() public {
        bytes memory payload = abi.encodeWithSignature(
            "executeProtection(address,uint256,uint8,bytes32,uint256,uint16,uint16,uint64,uint256,uint256)",
            address(0),
            7,
            uint8(0),
            OmniGuardTypes.MARKET_WETH_USDC,
            uint256(3000_00000000),
            uint16(1000),
            uint16(0),
            uint64(block.timestamp),
            uint256(12345),
            uint256(2)
        );
        ISystemContract.CallbackConfiguration_V_1_0 memory cfg = ISystemContract.CallbackConfiguration_V_1_0({
            chainId: UNICHAIN_SEPOLIA_CHAIN_ID,
            recipient: address(unichainVault),
            gasLimit: 500_000,
            payload: payload
        });

        (bool firstOk,) = unichainProxy.deliverCallback(address(reactiveGuard), cfg, 0);
        assertTrue(firstOk);

        (bool secondOk, bytes memory err) = unichainProxy.deliverCallback(address(reactiveGuard), cfg, 0);
        assertFalse(secondOk);
        assertEq(err, abi.encodeWithSelector(OmniGuardVault.DuplicateCallbackExecution.selector, 12345, 2, 7));
    }

    function test_NonMatchingLogDoesNotRevertInReact() public {
        IReactive.LogRecord memory unknownLog = IReactive.LogRecord({
            chainId: BASE_SEPOLIA_CHAIN_ID,
            contractAddress: address(baseFeed),
            topic0: uint256(keccak256("SomeOtherEvent(uint256)")),
            topic1: 0,
            topic2: 0,
            topic3: 0,
            data: hex"deadbeef",
            blockNumber: block.number,
            opCode: 1,
            blockHash: 0,
            txHash: 42,
            logIndex: 0
        });

        bool ok = system.trigger(IReactive(payable(address(reactiveGuard))), unknownLog, 0);
        assertTrue(ok, "unknown logs must return silently without reverting");
        assertEq(system.callbackCount(), 0);
        assertEq(reactiveGuard.totalEventsProcessed(), 0, "unmatched logs should not inflate processed counter");
    }

    function test_CronHeartbeatEnableDisableAndTick() public {
        vm.startPrank(owner);
        reactiveGuard.enableCron(100);
        assertTrue(reactiveGuard.cronEnabled());
        vm.stopPrank();

        IReactive.LogRecord memory cronLog = IReactive.LogRecord({
            chainId: LASNA_CHAIN_ID,
            contractAddress: LEGACY_SYSTEM_ADDR,
            topic0: 0xb49937fb8970e19fd46d48f7e3fb00d659deac0347f79cd7cb542f0fc1503c70,
            topic1: 0,
            topic2: 0,
            topic3: 0,
            data: abi.encode(block.number),
            blockNumber: block.number,
            opCode: 1,
            blockHash: 0,
            txHash: 77,
            logIndex: 0
        });

        assertTrue(system.trigger(IReactive(payable(address(reactiveGuard))), cronLog, 0));
        assertEq(reactiveGuard.totalCronTicks(), 1);

        vm.prank(owner);
        reactiveGuard.disableCron();
        assertFalse(reactiveGuard.cronEnabled());
    }

    function test_DebtSettlementAndCoverDebtOwnerOnly() public {
        uint256 balBefore = address(reactiveGuard).balance;
        IReactive.LogRecord memory noopLog = IReactive.LogRecord({
            chainId: BASE_SEPOLIA_CHAIN_ID,
            contractAddress: address(baseFeed),
            topic0: 0,
            topic1: 0,
            topic2: 0,
            topic3: 0,
            data: "",
            blockNumber: block.number,
            opCode: 1,
            blockHash: 0,
            txHash: 88,
            logIndex: 0
        });

        system.trigger(IReactive(payable(address(reactiveGuard))), noopLog, 0.05 ether);
        assertEq(system.debt(address(reactiveGuard)), 0, "AbstractPayer.pay() settled debt inline");
        assertEq(address(reactiveGuard).balance, balBefore - 0.05 ether);

        vm.prank(attacker);
        vm.expectRevert(OmniGuardReactive.NotOwner.selector);
        reactiveGuard.coverDebt();

        vm.prank(attacker);
        vm.expectRevert(OmniGuardVault.NotOwner.selector);
        unichainVault.coverDebt();

        vm.startPrank(owner);
        reactiveGuard.coverDebt();
        unichainVault.coverDebt();
        vm.stopPrank();
    }

    function test_RuleValidationRejectsUnsafeGasLimit() public {
        OmniGuardTypes.CreateRuleParams memory params =
            _defaultStopLossRuleParams(address(unichainVault), UNICHAIN_SEPOLIA_CHAIN_ID);
        params.callbackGasLimit = 400_000; // Below V2 safe 450,000 floor

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                OmniGuardReactive.InvalidGasLimit.selector,
                uint64(400_000),
                OmniGuardTypes.MIN_CALLBACK_GAS_LIMIT,
                OmniGuardTypes.MAX_CALLBACK_GAS_LIMIT
            )
        );
        reactiveGuard.createRule(params);
    }

    // -------------------------------------------------------------------------
    // 8. V2 P0 Security Regression Suite (Closes C1, C2, H1, M1)
    // -------------------------------------------------------------------------
    function test_V2Security_UnauthorizedCreateRuleBlockedAndAllowlistWorks() public {
        OmniGuardTypes.CreateRuleParams memory hostile =
            _defaultStopLossRuleParams(address(unichainVault), UNICHAIN_SEPOLIA_CHAIN_ID);
        hostile.priceFloorE8 = 99_999_00000000;
        hostile.hedgeBps = 10_000;

        // C1: Stranger cannot register a rule to drain/move the shared vault or spend lREACT.
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OmniGuardReactive.NotAuthorizedRuleCreator.selector, attacker));
        reactiveGuard.createRule(hostile);
        assertEq(reactiveGuard.nextRuleId(), 1);

        // Allowlisted operator CAN register a rule targeting an allowlisted vault.
        vm.prank(owner);
        reactiveGuard.setRuleCreator(operator, true);

        vm.prank(operator);
        uint256 id = reactiveGuard.createRule(_defaultStopLossRuleParams(address(unichainVault), UNICHAIN_SEPOLIA_CHAIN_ID));
        assertEq(id, 1);

        // Revoking operator blocks subsequent rule creation immediately.
        vm.prank(owner);
        reactiveGuard.setRuleCreator(operator, false);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(OmniGuardReactive.NotAuthorizedRuleCreator.selector, operator));
        reactiveGuard.createRule(_defaultStopLossRuleParams(address(unichainVault), UNICHAIN_SEPOLIA_CHAIN_ID));
    }

    function test_V2Security_UnallowlistedDestinationVaultBlocked() public {
        address rogueVault = makeAddr("rogueVault");
        OmniGuardTypes.CreateRuleParams memory params = _defaultStopLossRuleParams(rogueVault, 999999);

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(OmniGuardReactive.DestinationVaultNotAllowed.selector, 999999, rogueVault)
        );
        reactiveGuard.createRule(params);
    }

    function test_V2Security_RuleCapAndSwapPopPruningPreventsGasDoS() public {
        vm.startPrank(owner);
        for (uint256 i = 0; i < OmniGuardTypes.MAX_ACTIVE_RULES_PER_MARKET; ++i) {
            reactiveGuard.createRule(_defaultStopLossRuleParams(address(unichainVault), UNICHAIN_SEPOLIA_CHAIN_ID));
        }

        // 9th rule on same market must revert RuleCapExceeded(8).
        vm.expectRevert(
            abi.encodeWithSelector(
                OmniGuardReactive.RuleCapExceeded.selector, OmniGuardTypes.MAX_ACTIVE_RULES_PER_MARKET
            )
        );
        reactiveGuard.createRule(_defaultStopLossRuleParams(address(unichainVault), UNICHAIN_SEPOLIA_CHAIN_ID));

        assertEq(reactiveGuard.getMarketRuleIds(OmniGuardTypes.MARKET_WETH_USDC).length, 8);
        assertEq(reactiveGuard.activeRulesCount(), 8);

        // Deactivate 4 rules -> swap-and-pop removes them immediately from active iteration array.
        for (uint256 id = 1; id <= 4; ++id) {
            reactiveGuard.setRuleActive(id, false);
        }
        assertEq(reactiveGuard.getMarketRuleIds(OmniGuardTypes.MARKET_WETH_USDC).length, 4);
        assertEq(reactiveGuard.activeRulesCount(), 4);

        // New rules can now take those freed slots cleanly.
        reactiveGuard.createRule(_defaultStopLossRuleParams(address(unichainVault), UNICHAIN_SEPOLIA_CHAIN_ID));
        assertEq(reactiveGuard.getMarketRuleIds(OmniGuardTypes.MARKET_WETH_USDC).length, 5);
        vm.stopPrank();
    }

    function test_V2Security_EmergencyPauseSilencesReactAndBlocksVault() public {
        vm.startPrank(owner);
        reactiveGuard.createRule(_defaultStopLossRuleParams(address(unichainVault), UNICHAIN_SEPOLIA_CHAIN_ID));
        reactiveGuard.pause();

        // While paused, createRule reverts ContractPaused().
        vm.expectRevert(OmniGuardReactive.ContractPaused.selector);
        reactiveGuard.createRule(_defaultStopLossRuleParams(address(unichainVault), UNICHAIN_SEPOLIA_CHAIN_ID));

        // While paused, react() returns cleanly (no revert!) with 0 callbacks dispatched.
        vm.recordLogs();
        baseFeed.simulateFlashCrash(OmniGuardTypes.MARKET_WETH_USDC, 600, 900);
        uint256 deliveredWhilePaused = _relayRecordedLogs(vm.getRecordedLogs(), BASE_SEPOLIA_CHAIN_ID, 2, 0, 0);
        assertEq(deliveredWhilePaused, 0, "paused reactive contract dispatches zero callbacks");

        // Unpause reactive, pause destination vault -> vault callback reverts VaultPaused().
        reactiveGuard.unpause();
        unichainVault.pause();
        vm.stopPrank();

        bytes memory payload = abi.encodeWithSignature(
            "executeProtection(address,uint256,uint8,bytes32,uint256,uint16,uint16,uint64,uint256,uint256)",
            address(0),
            1,
            uint8(0),
            OmniGuardTypes.MARKET_WETH_USDC,
            uint256(3000_00000000),
            uint16(2000),
            uint16(0),
            uint64(block.timestamp),
            uint256(777),
            uint256(0)
        );
        (bool ok, bytes memory err) = unichainProxy.deliverCallback(
            address(reactiveGuard),
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: UNICHAIN_SEPOLIA_CHAIN_ID,
                recipient: address(unichainVault),
                gasLimit: 500_000,
                payload: payload
            }),
            0
        );
        assertFalse(ok);
        assertEq(err, abi.encodeWithSelector(OmniGuardVault.VaultPaused.selector));

        vm.prank(owner);
        unichainVault.unpause();
        (bool okAfterUnpause,) = unichainProxy.deliverCallback(
            address(reactiveGuard),
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: UNICHAIN_SEPOLIA_CHAIN_ID,
                recipient: address(unichainVault),
                gasLimit: 500_000,
                payload: payload
            }),
            0
        );
        assertTrue(okAfterUnpause);
    }

    function test_V2Security_CircuitBreakerHaltsFollowUpCallbacksUntilCleared() public {
        // Trip circuit breaker via CIRCUIT_BREAKER_PAUSE callback.
        bytes memory tripPayload = abi.encodeWithSignature(
            "executeProtection(address,uint256,uint8,bytes32,uint256,uint16,uint16,uint64,uint256,uint256)",
            address(0),
            3,
            uint8(OmniGuardTypes.ActionType.CIRCUIT_BREAKER_PAUSE),
            OmniGuardTypes.MARKET_WETH_USDC,
            uint256(2950_00000000),
            uint16(5000),
            uint16(9120),
            uint64(block.timestamp),
            uint256(5001),
            uint256(0)
        );
        (bool tripped,) = unichainProxy.deliverCallback(
            address(reactiveGuard),
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: UNICHAIN_SEPOLIA_CHAIN_ID,
                recipient: address(unichainVault),
                gasLimit: 500_000,
                payload: tripPayload
            }),
            0
        );
        assertTrue(tripped);
        assertTrue(unichainVault.getPosition(OmniGuardTypes.MARKET_WETH_USDC).circuitBreakerActive);

        // Follow-up hedge callback MUST revert CircuitBreakerActive(WETH/USDC).
        bytes memory followupHedge = abi.encodeWithSignature(
            "executeProtection(address,uint256,uint8,bytes32,uint256,uint16,uint16,uint64,uint256,uint256)",
            address(0),
            1,
            uint8(OmniGuardTypes.ActionType.HEDGE_TO_STABLE),
            OmniGuardTypes.MARKET_WETH_USDC,
            uint256(2900_00000000),
            uint16(2500),
            uint16(0),
            uint64(block.timestamp),
            uint256(5002),
            uint256(0)
        );
        (bool hedgeOk, bytes memory hedgeErr) = unichainProxy.deliverCallback(
            address(reactiveGuard),
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: UNICHAIN_SEPOLIA_CHAIN_ID,
                recipient: address(unichainVault),
                gasLimit: 500_000,
                payload: followupHedge
            }),
            0
        );
        assertFalse(hedgeOk);
        assertEq(
            hedgeErr, abi.encodeWithSelector(OmniGuardVault.CircuitBreakerActive.selector, OmniGuardTypes.MARKET_WETH_USDC)
        );

        // Follow-up cross-chain rebalance MUST also revert CircuitBreakerActive(WETH/USDC).
        bytes memory followupRebal = abi.encodeWithSignature(
            "executeCrossChainRebalance(address,uint256,bytes32,uint256,uint256,uint16,uint64,uint256,uint256)",
            address(0),
            4,
            OmniGuardTypes.MARKET_WETH_USDC,
            uint256(3200_00000000),
            uint256(3100_00000000),
            uint16(2000),
            uint64(block.timestamp),
            uint256(5003),
            uint256(0)
        );
        (bool rebalOk, bytes memory rebalErr) = unichainProxy.deliverCallback(
            address(reactiveGuard),
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: UNICHAIN_SEPOLIA_CHAIN_ID,
                recipient: address(unichainVault),
                gasLimit: 500_000,
                payload: followupRebal
            }),
            0
        );
        assertFalse(rebalOk);
        assertEq(
            rebalErr, abi.encodeWithSelector(OmniGuardVault.CircuitBreakerActive.selector, OmniGuardTypes.MARKET_WETH_USDC)
        );

        // Owner clears circuit breaker -> follow-up hedge succeeds cleanly.
        vm.prank(owner);
        unichainVault.clearCircuitBreaker(OmniGuardTypes.MARKET_WETH_USDC);
        (bool resumedOk,) = unichainProxy.deliverCallback(
            address(reactiveGuard),
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: UNICHAIN_SEPOLIA_CHAIN_ID,
                recipient: address(unichainVault),
                gasLimit: 500_000,
                payload: followupHedge
            }),
            0
        );
        assertTrue(resumedOk);
    }

    function test_V2Security_RollingWindowActionCapAndSingleActionBpsCap() public {
        vm.prank(owner);
        unichainVault.setCircuitBreakerCaps(2, 5000);

        // Exceeding single-action bps cap (6000 > 5000) reverts ActionBpsExceedsCap.
        bytes memory overBpsPayload = abi.encodeWithSignature(
            "executeProtection(address,uint256,uint8,bytes32,uint256,uint16,uint16,uint64,uint256,uint256)",
            address(0),
            1,
            uint8(0),
            OmniGuardTypes.MARKET_WETH_USDC,
            uint256(3000_00000000),
            uint16(6000),
            uint16(0),
            uint64(block.timestamp),
            uint256(9001),
            uint256(0)
        );
        (bool okBps, bytes memory errBps) = unichainProxy.deliverCallback(
            address(reactiveGuard),
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: UNICHAIN_SEPOLIA_CHAIN_ID,
                recipient: address(unichainVault),
                gasLimit: 500_000,
                payload: overBpsPayload
            }),
            0
        );
        assertFalse(okBps);
        assertEq(errBps, abi.encodeWithSelector(OmniGuardVault.ActionBpsExceedsCap.selector, 6000, 5000));

        // 2 actions inside 1 hour succeed; 3rd reverts WindowActionCapExceeded.
        for (uint256 k = 0; k < 2; ++k) {
            bytes memory p = abi.encodeWithSignature(
                "executeProtection(address,uint256,uint8,bytes32,uint256,uint16,uint16,uint64,uint256,uint256)",
                address(0),
                1,
                uint8(0),
                OmniGuardTypes.MARKET_WETH_USDC,
                uint256(3000_00000000),
                uint16(1000),
                uint16(0),
                uint64(block.timestamp),
                uint256(9100 + k),
                uint256(0)
            );
            (bool ok,) = unichainProxy.deliverCallback(
                address(reactiveGuard),
                ISystemContract.CallbackConfiguration_V_1_0({
                    chainId: UNICHAIN_SEPOLIA_CHAIN_ID,
                    recipient: address(unichainVault),
                    gasLimit: 500_000,
                    payload: p
                }),
                0
            );
            assertTrue(ok);
        }

        bytes memory thirdPayload = abi.encodeWithSignature(
            "executeProtection(address,uint256,uint8,bytes32,uint256,uint16,uint16,uint64,uint256,uint256)",
            address(0),
            1,
            uint8(0),
            OmniGuardTypes.MARKET_WETH_USDC,
            uint256(3000_00000000),
            uint16(1000),
            uint16(0),
            uint64(block.timestamp),
            uint256(9103),
            uint256(0)
        );
        (bool thirdOk, bytes memory thirdErr) = unichainProxy.deliverCallback(
            address(reactiveGuard),
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: UNICHAIN_SEPOLIA_CHAIN_ID,
                recipient: address(unichainVault),
                gasLimit: 500_000,
                payload: thirdPayload
            }),
            0
        );
        assertFalse(thirdOk);
        assertEq(
            thirdErr,
            abi.encodeWithSelector(
                OmniGuardVault.WindowActionCapExceeded.selector, OmniGuardTypes.MARKET_WETH_USDC, uint16(2)
            )
        );

        // Advance past 1-hour rolling window -> resets cleanly and executes!
        vm.warp(block.timestamp + unichainVault.BREAKER_WINDOW_SECONDS());
        (bool afterWindowOk,) = unichainProxy.deliverCallback(
            address(reactiveGuard),
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: UNICHAIN_SEPOLIA_CHAIN_ID,
                recipient: address(unichainVault),
                gasLimit: 500_000,
                payload: thirdPayload
            }),
            0
        );
        assertTrue(afterWindowOk);
    }

    function test_V2Security_RuleKindActionBindingAndNoSilentNoOp() public {
        OmniGuardTypes.CreateRuleParams memory mismatch =
            _defaultStopLossRuleParams(address(unichainVault), UNICHAIN_SEPOLIA_CHAIN_ID);
        mismatch.actionType = OmniGuardTypes.ActionType.CROSS_CHAIN_REBALANCE;

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                OmniGuardReactive.IncompatibleRuleAction.selector,
                OmniGuardTypes.RuleKind.STOP_LOSS_HEDGE,
                OmniGuardTypes.ActionType.CROSS_CHAIN_REBALANCE
            )
        );
        reactiveGuard.createRule(mismatch);

        // AI_REGIME_ESCALATION with aiRiskThresholdBps == 0 reverts MissingTriggerCondition.
        OmniGuardTypes.CreateRuleParams memory zeroAi = OmniGuardTypes.CreateRuleParams({
            marketId: OmniGuardTypes.MARKET_WETH_USDC,
            monitoredVault: address(0),
            destinationChainId: UNICHAIN_SEPOLIA_CHAIN_ID,
            destinationVault: address(unichainVault),
            kind: OmniGuardTypes.RuleKind.AI_REGIME_ESCALATION,
            actionType: OmniGuardTypes.ActionType.CIRCUIT_BREAKER_PAUSE,
            priceFloorE8: 0,
            maxDrawdownBps: 0,
            minHealthFactorBps: 0,
            aiRiskThresholdBps: 0,
            spreadThresholdBps: 0,
            hedgeBps: 5000,
            cooldownSeconds: 30,
            expiresAt: 0,
            callbackGasLimit: 500_000,
            adaptiveAiEnabled: true
        });
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                OmniGuardReactive.MissingTriggerCondition.selector, OmniGuardTypes.RuleKind.AI_REGIME_ESCALATION
            )
        );
        reactiveGuard.createRule(zeroAi);

        // Vault executeProtection rejects CROSS_CHAIN_REBALANCE (3) instead of writing a no-op receipt.
        bytes memory noopPayload = abi.encodeWithSignature(
            "executeProtection(address,uint256,uint8,bytes32,uint256,uint16,uint16,uint64,uint256,uint256)",
            address(0),
            1,
            uint8(OmniGuardTypes.ActionType.CROSS_CHAIN_REBALANCE),
            OmniGuardTypes.MARKET_WETH_USDC,
            uint256(3000_00000000),
            uint16(2000),
            uint16(0),
            uint64(block.timestamp),
            uint256(8080),
            uint256(0)
        );
        (bool ok, bytes memory err) = unichainProxy.deliverCallback(
            address(reactiveGuard),
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: UNICHAIN_SEPOLIA_CHAIN_ID,
                recipient: address(unichainVault),
                gasLimit: 500_000,
                payload: noopPayload
            }),
            0
        );
        assertFalse(ok);
        assertEq(err, abi.encodeWithSelector(OmniGuardVault.InvalidActionType.selector, uint8(3)));
    }

    function test_V2Security_StaleCrossChainSpreadLegRejected() public {
        vm.startPrank(owner);
        reactiveGuard.setSecondaryOriginFeed(UNICHAIN_SEPOLIA_CHAIN_ID, address(unichainFeed));
        reactiveGuard.createRule(
            OmniGuardTypes.CreateRuleParams({
                marketId: OmniGuardTypes.MARKET_WETH_USDC,
                monitoredVault: address(0),
                destinationChainId: UNICHAIN_SEPOLIA_CHAIN_ID,
                destinationVault: address(unichainVault),
                kind: OmniGuardTypes.RuleKind.CROSS_CHAIN_REBALANCE,
                actionType: OmniGuardTypes.ActionType.CROSS_CHAIN_REBALANCE,
                priceFloorE8: 0,
                maxDrawdownBps: 0,
                minHealthFactorBps: 0,
                aiRiskThresholdBps: 0,
                spreadThresholdBps: 150,
                hedgeBps: 2500,
                cooldownSeconds: 20,
                expiresAt: 0,
                callbackGasLimit: 500_000,
                adaptiveAiEnabled: false
            })
        );
        vm.stopPrank();

        // Base tick at T.
        vm.recordLogs();
        vm.prank(owner);
        baseFeed.postPriceTick(OmniGuardTypes.MARKET_WETH_USDC, 3200_00000000, 140);
        assertEq(_relayRecordedLogs(vm.getRecordedLogs(), BASE_SEPOLIA_CHAIN_ID, 0, 0, 0), 0);

        // Warp 121 seconds (> 120s freshness window) and post Unichain tick with 3.22% spread -> MUST NOT rebalance!
        vm.warp(block.timestamp + 121);
        vm.recordLogs();
        vm.prank(owner);
        unichainFeed.postPriceTick(OmniGuardTypes.MARKET_WETH_USDC, 3100_00000000, 200);
        assertEq(
            _relayRecordedLogs(vm.getRecordedLogs(), UNICHAIN_SEPOLIA_CHAIN_ID, 0, 0, 0),
            0,
            "stale primary price leg must not trigger cross-chain rebalance"
        );

        // Fresh Base tick 5 seconds later brings both legs inside 120s window -> triggers rebalance cleanly.
        vm.warp(block.timestamp + 5);
        vm.recordLogs();
        vm.prank(owner);
        baseFeed.postPriceTick(OmniGuardTypes.MARKET_WETH_USDC, 3200_00000000, 160);
        assertEq(_relayRecordedLogs(vm.getRecordedLogs(), BASE_SEPOLIA_CHAIN_ID, 2, 0, 0), 1);
    }

    function test_V2Security_NeuralTtlBoundAndSignerRotationInvalidatesSnapshot() public {
        vm.prank(owner);
        uint256 ruleId = reactiveGuard.createRule(_defaultStopLossRuleParams(address(unichainVault), UNICHAIN_SEPOLIA_CHAIN_ID));

        // Unbounded TTL (> now + 180s) reverts AdvisementTtlTooLong.
        OmniMarketFeed.NeuralAdvisement memory longTtl = OmniMarketFeed.NeuralAdvisement({
            marketId: OmniGuardTypes.MARKET_WETH_USDC,
            regime: uint8(OmniGuardTypes.RiskRegime.CASCADE_CRITICAL),
            riskScoreBps: 9200,
            recommendedHedgeBps: 6500,
            issuedAt: uint64(block.timestamp),
            validUntil: uint64(block.timestamp + 600),
            nonce: 0
        });
        bytes memory longSig = _signAdvisement(longTtl, NEURAL_SIGNER_PK);
        vm.expectRevert(
            abi.encodeWithSelector(
                OmniMarketFeed.AdvisementTtlTooLong.selector,
                uint64(block.timestamp + 600),
                uint64(block.timestamp + OmniGuardTypes.MAX_ADVISEMENT_TTL_SECONDS)
            )
        );
        baseFeed.submitSignedNeuralRegime(longTtl, longSig);

        // Valid 180s advisement synchronizes to Lasna and tightens 400 -> 260 bps.
        OmniMarketFeed.NeuralAdvisement memory validAdv = OmniMarketFeed.NeuralAdvisement({
            marketId: OmniGuardTypes.MARKET_WETH_USDC,
            regime: uint8(OmniGuardTypes.RiskRegime.CASCADE_CRITICAL),
            riskScoreBps: 9200,
            recommendedHedgeBps: 6500,
            issuedAt: uint64(block.timestamp),
            validUntil: uint64(block.timestamp + 180),
            nonce: 0
        });
        bytes memory validSig = _signAdvisement(validAdv, NEURAL_SIGNER_PK);
        vm.recordLogs();
        baseFeed.submitSignedNeuralRegime(validAdv, validSig);
        _relayRecordedLogs(vm.getRecordedLogs(), BASE_SEPOLIA_CHAIN_ID, 1, 0, 0);

        (uint16 tightenedBefore,) = reactiveGuard.getEffectiveDrawdownBps(ruleId, uint64(block.timestamp));
        assertEq(tightenedBefore, 260);

        // Rotate neural signer -> old snapshot immediately ignored on both feed and reactive contract!
        address newSigner = vm.addr(NEW_NEURAL_SIGNER_PK);
        vm.startPrank(owner);
        baseFeed.setNeuralSigner(newSigner);
        reactiveGuard.setTrustedNeuralSigner(newSigner);
        vm.stopPrank();

        assertEq(baseFeed.getActiveNeuralState(OmniGuardTypes.MARKET_WETH_USDC).signer, address(0));
        (uint16 restoredAfterRotation, uint16 riskAfterRotation) =
            reactiveGuard.getEffectiveDrawdownBps(ruleId, uint64(block.timestamp));
        assertEq(restoredAfterRotation, 400, "rotated signer snapshot must not tighten drawdown");
        assertEq(riskAfterRotation, 0);
    }

    function test_V2Security_SameTxMultiLogIndexAndTwoStepOwnership() public {
        // Two callbacks with same originTxHash and ruleId but distinct logIndex (0 vs 1) both succeed.
        for (uint256 logIdx = 0; logIdx < 2; ++logIdx) {
            bytes memory p = abi.encodeWithSignature(
                "executeProtection(address,uint256,uint8,bytes32,uint256,uint16,uint16,uint64,uint256,uint256)",
                address(0),
                1,
                uint8(0),
                OmniGuardTypes.MARKET_WETH_USDC,
                uint256(3000_00000000),
                uint16(1000),
                uint16(0),
                uint64(block.timestamp),
                uint256(44444),
                logIdx
            );
            (bool ok,) = unichainProxy.deliverCallback(
                address(reactiveGuard),
                ISystemContract.CallbackConfiguration_V_1_0({
                    chainId: UNICHAIN_SEPOLIA_CHAIN_ID,
                    recipient: address(unichainVault),
                    gasLimit: 500_000,
                    payload: p
                }),
                0
            );
            assertTrue(ok);
        }

        // Two-step ownership transfer across feed, reactive, and vault.
        vm.startPrank(owner);
        baseFeed.transferOwnership(operator);
        reactiveGuard.transferOwnership(operator);
        unichainVault.transferOwnership(operator);
        vm.stopPrank();

        vm.prank(attacker);
        vm.expectRevert(OmniGuardReactive.NotPendingOwner.selector);
        reactiveGuard.acceptOwnership();

        vm.startPrank(operator);
        baseFeed.acceptOwnership();
        reactiveGuard.acceptOwnership();
        unichainVault.acceptOwnership();
        vm.stopPrank();

        assertEq(baseFeed.owner(), operator);
        assertEq(reactiveGuard.owner(), operator);
        assertEq(unichainVault.owner(), operator);
    }

    // -------------------------------------------------------------------------
    // 9. Fuzz Test: Portfolio Value Conservation Across Random Crash & Hedge Ratios
    // -------------------------------------------------------------------------
    function testFuzz_StopLossDrawdownAndHedgeAccounting(uint16 dropBps_, uint16 hedgeBps_) public {
        dropBps_ = uint16(bound(dropBps_, 350, 9000));
        hedgeBps_ = uint16(bound(hedgeBps_, 100, 10_000));

        vm.prank(owner);
        reactiveGuard.createRule(
            OmniGuardTypes.CreateRuleParams({
                marketId: OmniGuardTypes.MARKET_WETH_USDC,
                monitoredVault: address(0),
                destinationChainId: UNICHAIN_SEPOLIA_CHAIN_ID,
                destinationVault: address(unichainVault),
                kind: OmniGuardTypes.RuleKind.STOP_LOSS_HEDGE,
                actionType: OmniGuardTypes.ActionType.HEDGE_TO_STABLE,
                priceFloorE8: 0,
                maxDrawdownBps: 300,
                minHealthFactorBps: 0,
                aiRiskThresholdBps: 0,
                spreadThresholdBps: 0,
                hedgeBps: hedgeBps_,
                cooldownSeconds: 10,
                expiresAt: 0,
                callbackGasLimit: 500_000,
                adaptiveAiEnabled: false
            })
        );

        OmniGuardVault.VaultPosition memory beforePos = unichainVault.getPosition(OmniGuardTypes.MARKET_WETH_USDC);
        uint256 totalAssetsBefore = beforePos.volatileCollateralUsdE8 + beforePos.stableReserveUsdE8;

        vm.recordLogs();
        vm.prank(owner);
        baseFeed.simulateFlashCrash(OmniGuardTypes.MARKET_WETH_USDC, dropBps_, 600);
        uint256 delivered = _relayRecordedLogs(vm.getRecordedLogs(), BASE_SEPOLIA_CHAIN_ID, 2, 0, 0);
        assertEq(delivered, 1);

        OmniGuardVault.VaultPosition memory afterPos = unichainVault.getPosition(OmniGuardTypes.MARKET_WETH_USDC);
        uint256 totalAssetsAfter = afterPos.volatileCollateralUsdE8 + afterPos.stableReserveUsdE8;

        assertEq(totalAssetsAfter, totalAssetsBefore, "total portfolio value strictly conserved");
        assertLe(afterPos.volatileCollateralUsdE8, beforePos.volatileCollateralUsdE8);
        assertGe(afterPos.stableReserveUsdE8, beforePos.stableReserveUsdE8);
    }
}
