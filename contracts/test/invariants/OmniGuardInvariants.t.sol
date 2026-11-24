// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import { Test, Vm } from "forge-std/Test.sol";
import { StdInvariant } from "forge-std/StdInvariant.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";

import { OmniGuardTypes } from "../../src/interfaces/IOmniGuardTypes.sol";
import { OmniMarketFeed } from "../../src/origin/OmniMarketFeed.sol";
import { OmniGuardReactive } from "../../src/reactive/OmniGuardReactive.sol";
import { OmniGuardVault } from "../../src/destination/OmniGuardVault.sol";
import { MockOmniSystem } from "../mocks/MockOmniSystem.sol";
import { MockOmniCallbackProxy } from "../mocks/MockOmniCallbackProxy.sol";

/**
 * @title OmniGuardHandler
 * @notice Bounded multi-actor Foundry invariant handler exercising owner, attacker, neural signer,
 *         Base Sepolia 200ms block rolls, circuit-breaker lockouts, and rule cap churn.
 */
contract OmniGuardHandler is Test {
    uint256 internal constant BASE_SEPOLIA_CHAIN_ID = 84532;
    uint256 internal constant UNICHAIN_SEPOLIA_CHAIN_ID = 1301;
    uint256 internal constant NEURAL_SIGNER_PK = 0xA11CE001;

    address public immutable owner;
    address public immutable attacker;
    address public immutable neuralSigner;

    MockOmniSystem public immutable system;
    MockOmniCallbackProxy public immutable unichainProxy;
    OmniMarketFeed public immutable baseFeed;
    OmniGuardReactive public immutable reactiveGuard;
    OmniGuardVault public immutable unichainVault;

    uint256 public initialTotalAssets;
    uint256 public initialDebt;
    uint256 public stopLossRuleId;
    uint256 public aiRuleId;

    // Ghost variables tracking strict protocol invariants across arbitrary call sequences
    uint256 public ghostTotalCallbacksExecuted;
    uint256 public ghostAttackerRulesCreated;
    uint256 public ghostExecutionsWhileCircuitBreakerActive;
    uint256 public ghostExecutionsWhileVaultPaused;
    uint256 public ghostCooldownViolations;
    uint64 public ghostLastStopLossTs;
    uint256 private _txCounter = 5000;

    constructor(
        address owner_,
        address attacker_,
        MockOmniSystem system_,
        MockOmniCallbackProxy unichainProxy_,
        OmniMarketFeed baseFeed_,
        OmniGuardReactive reactiveGuard_,
        OmniGuardVault unichainVault_
    ) {
        owner = owner_;
        attacker = attacker_;
        neuralSigner = vm.addr(NEURAL_SIGNER_PK);
        system = system_;
        unichainProxy = unichainProxy_;
        baseFeed = baseFeed_;
        reactiveGuard = reactiveGuard_;
        unichainVault = unichainVault_;

        OmniGuardVault.VaultPosition memory p = unichainVault.getPosition(OmniGuardTypes.MARKET_WETH_USDC);
        initialTotalAssets = p.volatileCollateralUsdE8 + p.stableReserveUsdE8;
        initialDebt = p.debtUsdE8;

        vm.startPrank(owner);
        stopLossRuleId = reactiveGuard.createRule(
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
                hedgeBps: 2500,
                cooldownSeconds: 30,
                expiresAt: 0,
                callbackGasLimit: 500_000,
                adaptiveAiEnabled: true
            })
        );
        aiRuleId = reactiveGuard.createRule(
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
                aiRiskThresholdBps: 8000,
                spreadThresholdBps: 0,
                hedgeBps: 3000,
                cooldownSeconds: 45,
                expiresAt: 0,
                callbackGasLimit: 500_000,
                adaptiveAiEnabled: true
            })
        );
        vm.stopPrank();
    }

    function actorFlashCrash(uint16 dropBps_, uint64 timeDeltaSec_, uint64 fastBlocks_) external {
        dropBps_ = uint16(bound(dropBps_, 100, 4500));
        timeDeltaSec_ = uint64(bound(timeDeltaSec_, 0, 180));
        fastBlocks_ = uint64(bound(fastBlocks_, 1, 200));

        vm.roll(block.number + fastBlocks_);
        vm.warp(block.timestamp + timeDeltaSec_);

        // Reset feed price upward occasionally so price never hits 1 wei floor permanently
        (uint256 lastP,,) = baseFeed.markets(OmniGuardTypes.MARKET_WETH_USDC);
        if (lastP < 500_00000000) {
            vm.prank(owner);
            baseFeed.postPriceTick(OmniGuardTypes.MARKET_WETH_USDC, 3200_00000000, 150);
        }

        uint64 originTs = uint64(block.timestamp);
        vm.recordLogs();
        vm.prank(owner);
        baseFeed.simulateFlashCrash(OmniGuardTypes.MARKET_WETH_USDC, dropBps_, 700);
        _relay(vm.getRecordedLogs(), originTs);
    }

    function actorNeuralCascade(uint16 riskScoreBps_, uint64 timeDeltaSec_) external {
        riskScoreBps_ = uint16(bound(riskScoreBps_, 5000, 9800));
        timeDeltaSec_ = uint64(bound(timeDeltaSec_, 1, 240));
        vm.warp(block.timestamp + timeDeltaSec_);

        uint64 nowTs = uint64(block.timestamp);
        uint256 nonce = baseFeed.neuralNonces(OmniGuardTypes.MARKET_WETH_USDC);
        OmniMarketFeed.NeuralAdvisement memory adv = OmniMarketFeed.NeuralAdvisement({
            marketId: OmniGuardTypes.MARKET_WETH_USDC,
            regime: riskScoreBps_ >= 8000 ? 3 : 2,
            riskScoreBps: riskScoreBps_,
            recommendedHedgeBps: 4000,
            issuedAt: nowTs,
            validUntil: nowTs + 150,
            nonce: nonce
        });
        bytes32 digest = baseFeed.hashNeuralAdvisement(adv);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(NEURAL_SIGNER_PK, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.recordLogs();
        baseFeed.submitSignedNeuralRegime(adv, sig);
        _relay(vm.getRecordedLogs(), nowTs);
    }

    function actorTogglePause(bool reactivePause_, bool vaultPause_) external {
        vm.startPrank(owner);
        if (reactivePause_) reactiveGuard.pause();
        else reactiveGuard.unpause();

        if (vaultPause_) unichainVault.pause();
        else unichainVault.unpause();
        vm.stopPrank();
    }

    function actorClearBreakerAndAdvanceWindow(bool advanceFullWindow_) external {
        if (advanceFullWindow_) {
            vm.warp(block.timestamp + unichainVault.BREAKER_WINDOW_SECONDS() + 1);
        }
        vm.prank(owner);
        unichainVault.clearCircuitBreaker(OmniGuardTypes.MARKET_WETH_USDC);
    }

    function actorChurnOwnerRules(bool createNew_, uint256 ruleIdSeed_) external {
        vm.startPrank(owner);
        if (createNew_) {
            try reactiveGuard.createRule(
                OmniGuardTypes.CreateRuleParams({
                    marketId: OmniGuardTypes.MARKET_WETH_USDC,
                    monitoredVault: address(0),
                    destinationChainId: UNICHAIN_SEPOLIA_CHAIN_ID,
                    destinationVault: address(unichainVault),
                    kind: OmniGuardTypes.RuleKind.STOP_LOSS_HEDGE,
                    actionType: OmniGuardTypes.ActionType.HEDGE_TO_STABLE,
                    priceFloorE8: 0,
                    maxDrawdownBps: 500,
                    minHealthFactorBps: 0,
                    aiRiskThresholdBps: 0,
                    spreadThresholdBps: 0,
                    hedgeBps: 1500,
                    cooldownSeconds: 60,
                    expiresAt: 0,
                    callbackGasLimit: 500_000,
                    adaptiveAiEnabled: false
                })
            ) { } catch { }
        } else {
            uint256 maxId = reactiveGuard.nextRuleId();
            if (maxId > 3) {
                uint256 targetId = bound(ruleIdSeed_, 3, maxId - 1);
                try reactiveGuard.setRuleActive(targetId, false) { } catch { }
            }
        }
        vm.stopPrank();
    }

    function attackerAttemptRuleHijackAndUnauthorizedCalls(uint16 hedgeBps_) external {
        hedgeBps_ = uint16(bound(hedgeBps_, 1, 10_000));
        vm.startPrank(attacker);
        try reactiveGuard.createRule(
            OmniGuardTypes.CreateRuleParams({
                marketId: OmniGuardTypes.MARKET_WETH_USDC,
                monitoredVault: address(0),
                destinationChainId: UNICHAIN_SEPOLIA_CHAIN_ID,
                destinationVault: address(unichainVault),
                kind: OmniGuardTypes.RuleKind.STOP_LOSS_HEDGE,
                actionType: OmniGuardTypes.ActionType.HEDGE_TO_STABLE,
                priceFloorE8: 99_999_00000000,
                maxDrawdownBps: 1,
                minHealthFactorBps: 0,
                aiRiskThresholdBps: 0,
                spreadThresholdBps: 0,
                hedgeBps: hedgeBps_,
                cooldownSeconds: 0,
                expiresAt: 0,
                callbackGasLimit: 500_000,
                adaptiveAiEnabled: false
            })
        ) {
            ghostAttackerRulesCreated++;
        } catch { }

        try unichainVault.executeProtection(
            address(reactiveGuard), 1, 0, OmniGuardTypes.MARKET_WETH_USDC, 3000_00000000, hedgeBps_, 0, 100, 999, 0
        ) {
            ghostTotalCallbacksExecuted++;
        } catch { }

        try unichainVault.clearCircuitBreaker(OmniGuardTypes.MARKET_WETH_USDC) { } catch { }
        try reactiveGuard.pause() { } catch { }
        vm.stopPrank();
    }

    function _relay(Vm.Log[] memory logs_, uint64 originTs_) internal {
        system.clearCallbacks();
        uint256 syntheticTxHash = uint256(keccak256(abi.encodePacked("inv", ++_txCounter, block.timestamp)));

        for (uint256 i = 0; i < logs_.length; ++i) {
            Vm.Log memory entry = logs_[i];
            if (entry.topics.length == 0) continue;
            uint256 t0 = uint256(entry.topics[0]);
            if (
                t0 != OmniGuardTypes.PRICE_UPDATED_TOPIC0 && t0 != OmniGuardTypes.NEURAL_REGIME_COMMITTED_TOPIC0
            ) continue;

            IReactive.LogRecord memory rec = IReactive.LogRecord({
                chainId: BASE_SEPOLIA_CHAIN_ID,
                contractAddress: entry.emitter,
                topic0: t0,
                topic1: entry.topics.length > 1 ? uint256(entry.topics[1]) : 0,
                topic2: entry.topics.length > 2 ? uint256(entry.topics[2]) : 0,
                topic3: entry.topics.length > 3 ? uint256(entry.topics[3]) : 0,
                data: entry.data,
                blockNumber: block.number,
                opCode: entry.topics.length,
                blockHash: 0,
                txHash: syntheticTxHash,
                logIndex: i
            });

            uint256 callbacksBefore = system.callbackCount();
            bool reactOk = system.trigger(IReactive(payable(address(reactiveGuard))), rec, 0);
            assertTrue(reactOk, "react() must never revert");

            if (t0 == OmniGuardTypes.PRICE_UPDATED_TOPIC0 && system.callbackCount() > callbacksBefore) {
                uint256 callbacksAfter = system.callbackCount();
                for (uint256 q = callbacksBefore; q < callbacksAfter; ++q) {
                    MockOmniSystem.RecordedCallback memory queuedCb = system.getCallback(q);
                    // Payload layout: 4-byte selector | 32-byte reactiveSender | 32-byte ruleId
                    uint256 cbRuleId;
                    bytes memory pl = queuedCb.config.payload;
                    assembly {
                        cbRuleId := mload(add(pl, 68))
                    }
                    if (cbRuleId == stopLossRuleId) {
                        if (ghostLastStopLossTs != 0 && originTs_ < ghostLastStopLossTs + 30) {
                            ghostCooldownViolations++;
                        }
                        ghostLastStopLossTs = originTs_;
                    }
                }
            }
        }

        uint256 count = system.callbackCount();
        for (uint256 c = 0; c < count; ++c) {
            MockOmniSystem.RecordedCallback memory cb = system.getCallback(c);
            bool breakerWasActive = unichainVault.getPosition(OmniGuardTypes.MARKET_WETH_USDC).circuitBreakerActive;
            bool vaultWasPaused = unichainVault.paused();

            (bool ok,) = unichainProxy.deliverCallback(cb.sender, cb.config, 0);
            if (ok) {
                ghostTotalCallbacksExecuted++;
                if (breakerWasActive) ghostExecutionsWhileCircuitBreakerActive++;
                if (vaultWasPaused) ghostExecutionsWhileVaultPaused++;
            }
        }
    }
}

/**
 * @title OmniGuardInvariantsTest
 * @notice Foundry stateful invariant suite verifying value conservation, access control, rule caps,
 *         circuit-breaker lockout, pause enforcement, and Base 200ms timestamp cooldown discipline.
 */
contract OmniGuardInvariantsTest is StdInvariant, Test {
    address internal constant SYSTEM_ADDR = 0x8888888888888888888888888888888888888888;
    uint256 internal constant BASE_SEPOLIA_CHAIN_ID = 84532;
    uint256 internal constant UNICHAIN_SEPOLIA_CHAIN_ID = 1301;
    uint256 internal constant NEURAL_SIGNER_PK = 0xA11CE001;

    address internal owner = makeAddr("inv_owner");
    address internal attacker = makeAddr("inv_attacker");

    MockOmniSystem internal system;
    MockOmniCallbackProxy internal unichainProxy;
    OmniMarketFeed internal baseFeed;
    OmniGuardReactive internal reactiveGuard;
    OmniGuardVault internal unichainVault;
    OmniGuardHandler internal handler;

    function setUp() public {
        vm.warp(1_795_500_000);
        vm.roll(62_831_270);

        MockOmniSystem systemImpl = new MockOmniSystem();
        vm.etch(SYSTEM_ADDR, address(systemImpl).code);
        system = MockOmniSystem(payable(SYSTEM_ADDR));
        unichainProxy = new MockOmniCallbackProxy();

        vm.deal(owner, 10 ether);
        address neuralSigner = vm.addr(NEURAL_SIGNER_PK);

        vm.startPrank(owner);
        baseFeed = new OmniMarketFeed(owner, neuralSigner, 3200_00000000);
        reactiveGuard = new OmniGuardReactive{ value: 1 ether }(BASE_SEPOLIA_CHAIN_ID, address(baseFeed), owner);
        unichainVault = new OmniGuardVault{ value: 0.5 ether }(
            IPayable(payable(address(unichainProxy))), address(reactiveGuard), owner
        );
        reactiveGuard.setAllowedDestinationVault(UNICHAIN_SEPOLIA_CHAIN_ID, address(unichainVault), true);
        reactiveGuard.setTrustedNeuralSigner(neuralSigner);
        vm.stopPrank();

        handler = new OmniGuardHandler(owner, attacker, system, unichainProxy, baseFeed, reactiveGuard, unichainVault);
        targetContract(address(handler));
    }

    /// @notice Total vault assets (volatile + stable) are strictly conserved across all hedges & circuit-breaker shifts.
    function invariant_PortfolioConservationHolds() public view {
        OmniGuardVault.VaultPosition memory p = unichainVault.getPosition(OmniGuardTypes.MARKET_WETH_USDC);
        uint256 debtRepaid = handler.initialDebt() - p.debtUsdE8;
        assertEq(
            p.volatileCollateralUsdE8 + p.stableReserveUsdE8 + debtRepaid,
            handler.initialTotalAssets(),
            "vault value must be strictly conserved"
        );
        assertLe(p.debtUsdE8, handler.initialDebt(), "debt must never increase");
    }

    /// @notice Unauthorized attackers can never create rules or hijack ownership on any contract.
    function invariant_AttackerNeverCreatesRulesOrHijacksOwnership() public view {
        assertEq(handler.ghostAttackerRulesCreated(), 0, "attacker must never create a rule");
        assertEq(reactiveGuard.owner(), owner);
        assertEq(unichainVault.owner(), owner);
        assertEq(baseFeed.owner(), owner);
    }

    /// @notice Active rule buckets remain strictly bounded to prevent Lasna 900k gas DoS.
    function invariant_ActiveRuleBucketsStrictlyBounded() public view {
        assertLe(
            reactiveGuard.getMarketRuleIds(OmniGuardTypes.MARKET_WETH_USDC).length,
            OmniGuardTypes.MAX_ACTIVE_RULES_PER_MARKET
        );
        assertLe(reactiveGuard.activeRulesCount(), OmniGuardTypes.MAX_TOTAL_ACTIVE_RULES);
    }

    /// @notice Circuit breaker and emergency pause can NEVER be bypassed by any callback sequence.
    function invariant_CircuitBreakerAndPauseNeverBypassed() public view {
        assertEq(
            handler.ghostExecutionsWhileCircuitBreakerActive(),
            0,
            "zero callbacks may execute while circuit breaker is active"
        );
        assertEq(handler.ghostExecutionsWhileVaultPaused(), 0, "zero callbacks may execute while vault is paused");
    }

    /// @notice Base Sepolia 200ms fast block rolls never bypass Unix timestamp cooldowns.
    function invariant_TimestampCooldownNeverBypassedByFastBlocks() public view {
        assertEq(handler.ghostCooldownViolations(), 0, "timestamp cooldown violated");
    }

    /// @notice On-chain receipt array count strictly equals verified executed callbacks.
    function invariant_ReceiptCountMatchesGhostExecutions() public view {
        assertEq(unichainVault.getReceiptsCount(), handler.ghostTotalCallbacksExecuted());
    }
}
