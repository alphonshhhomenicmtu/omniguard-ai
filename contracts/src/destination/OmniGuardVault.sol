// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";
import { OmniGuardTypes } from "../interfaces/IOmniGuardTypes.sol";

/**
 * @title OmniGuardVault
 * @notice Destination-chain autonomous DeFi protection and cross-chain rebalancing vault.
 * @dev Deployed on Unichain Sepolia (1301, proxy 0x775c9B990ADe401060B78D0e98684eEf8d2466C1)
 *      and/or Base Sepolia (84532, proxy 0x476F44b11F5C942c58f4c8E3d0300E5710743585).
 *      Inherits `AbstractCallback` from `reactive-lib-omni` and strictly guards every callback entrypoint
 *      with BOTH `onlyServiceProvider` AND `onlyCallbackSender(reactiveSender_)`.
 *      Records on-chain end-to-end latency in seconds using Unix timestamps exclusively (never block numbers).
 */
contract OmniGuardVault is AbstractCallback {
    /// @notice Protected portfolio accounting state per marketId (USD values scaled to 1e8).
    struct VaultPosition {
        uint256 volatileCollateralUsdE8;
        uint256 stableReserveUsdE8;
        uint256 debtUsdE8;
        uint256 rebalancedVolumeUsdE8;
        bool circuitBreakerActive;
        uint64 lastActionTimestamp;
    }

    /// @notice Verifiable on-chain execution receipt proving origin -> Reactive -> callback completion.
    struct ExecutionReceipt {
        uint256 receiptId;
        uint256 ruleId;
        OmniGuardTypes.ActionType actionType;
        bytes32 marketId;
        uint256 triggerPriceE8;
        uint16 appliedBps;
        uint16 aiRiskScoreBps;
        uint64 originTimestamp;
        uint64 callbackTimestamp;
        uint64 endToEndLatencySec;
        uint256 originTxHash;
        uint256 collateralBeforeUsdE8;
        uint256 collateralAfterUsdE8;
        uint256 stableAfterUsdE8;
        uint256 debtAfterUsdE8;
    }

    /// @notice Vault administrator.
    address public owner;

    /// @notice Portfolio state per marketId.
    mapping(bytes32 => VaultPosition) public positions;

    /// @notice Replay protection keyed by (originTxHash, ruleId).
    mapping(uint256 => mapping(uint256 => bool)) public executedOriginTx;

    /// @notice Chronological log of all callback execution receipts.
    ExecutionReceipt[] public receipts;

    event PositionConfigured(
        bytes32 indexed marketId,
        uint256 volatileCollateralUsdE8,
        uint256 stableReserveUsdE8,
        uint256 debtUsdE8,
        uint64 timestamp
    );

    event ProtectionExecuted(
        uint256 indexed receiptId,
        uint256 indexed ruleId,
        bytes32 indexed marketId,
        OmniGuardTypes.ActionType actionType,
        uint256 triggerPriceE8,
        uint16 appliedBps,
        uint16 aiRiskScoreBps,
        uint64 originTimestamp,
        uint64 callbackTimestamp,
        uint64 endToEndLatencySec,
        uint256 originTxHash
    );

    event CrossChainRebalanced(
        uint256 indexed receiptId,
        uint256 indexed ruleId,
        bytes32 indexed marketId,
        uint256 primaryPriceE8,
        uint256 secondaryPriceE8,
        uint256 spreadBps,
        uint256 rebalancedUsdE8,
        uint64 endToEndLatencySec,
        uint256 originTxHash
    );

    event CircuitBreakerCleared(bytes32 indexed marketId, uint64 timestamp);

    error NotOwner();
    error InvalidAddress();
    error InvalidBps(uint16 value);
    error InvalidActionType(uint8 actionType);
    error DuplicateCallbackExecution(uint256 originTxHash, uint256 ruleId);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /**
     * @notice Payable constructor so destination native ETH can be supplied for callback gas reimbursement.
     * @param callbackProxy_ Official Reactive Omni CallbackProxy address for this destination chain.
     * @param callbackSender_ Deployed OmniGuardReactive contract address on Reactive Lasna (5318007).
     * @param owner_ Vault administrator address.
     */
    constructor(IPayable callbackProxy_, address callbackSender_, address owner_)
        payable
        AbstractCallback(callbackProxy_, callbackSender_)
    {
        if (address(callbackProxy_) == address(0) || callbackSender_ == address(0) || owner_ == address(0)) {
            revert InvalidAddress();
        }
        owner = owner_;

        // Seed default WETH/USDC demo vault position ($100,000 volatile WETH, $25,000 USDC reserve, $60,000 debt).
        positions[OmniGuardTypes.MARKET_WETH_USDC] = VaultPosition({
            volatileCollateralUsdE8: 100_000_00000000,
            stableReserveUsdE8: 25_000_00000000,
            debtUsdE8: 60_000_00000000,
            rebalancedVolumeUsdE8: 0,
            circuitBreakerActive: false,
            lastActionTimestamp: uint64(block.timestamp)
        });
    }

    /// @notice Settles any outstanding debt to the destination CallbackProxy from this vault's ETH balance.
    function coverDebt() external {
        _coverDebt();
    }

    /// @notice Configures or resets a market position for live testnet demos or production onboarding.
    function configurePosition(
        bytes32 marketId_,
        uint256 volatileCollateralUsdE8_,
        uint256 stableReserveUsdE8_,
        uint256 debtUsdE8_
    ) external onlyOwner {
        positions[marketId_] = VaultPosition({
            volatileCollateralUsdE8: volatileCollateralUsdE8_,
            stableReserveUsdE8: stableReserveUsdE8_,
            debtUsdE8: debtUsdE8_,
            rebalancedVolumeUsdE8: 0,
            circuitBreakerActive: false,
            lastActionTimestamp: uint64(block.timestamp)
        });

        emit PositionConfigured(
            marketId_, volatileCollateralUsdE8_, stableReserveUsdE8_, debtUsdE8_, uint64(block.timestamp)
        );
    }

    /// @notice Clears an active circuit breaker after market stabilization.
    function clearCircuitBreaker(bytes32 marketId_) external onlyOwner {
        positions[marketId_].circuitBreakerActive = false;
        emit CircuitBreakerCleared(marketId_, uint64(block.timestamp));
    }

    /**
     * @notice Reactive Omni callback entrypoint for stop-loss hedging, health-factor deleveraging,
     *         and neural-escalated circuit-breaker protection.
     * @param reactiveSender_ First argument overwritten by Reactive Omni CallbackProxy with OmniGuardReactive address.
     */
    function executeProtection(
        address reactiveSender_,
        uint256 ruleId_,
        uint8 actionTypeRaw_,
        bytes32 marketId_,
        uint256 triggerPriceE8_,
        uint16 hedgeBps_,
        uint16 aiRiskScoreBps_,
        uint64 originTimestamp_,
        uint256 originTxHash_
    ) external onlyServiceProvider onlyCallbackSender(reactiveSender_) {
        if (actionTypeRaw_ > uint8(OmniGuardTypes.ActionType.CROSS_CHAIN_REBALANCE)) {
            revert InvalidActionType(actionTypeRaw_);
        }
        if (hedgeBps_ == 0 || hedgeBps_ > OmniGuardTypes.BPS_DENOMINATOR) {
            revert InvalidBps(hedgeBps_);
        }
        if (executedOriginTx[originTxHash_][ruleId_]) {
            revert DuplicateCallbackExecution(originTxHash_, ruleId_);
        }
        executedOriginTx[originTxHash_][ruleId_] = true;

        VaultPosition storage pos = positions[marketId_];
        uint256 collateralBefore = pos.volatileCollateralUsdE8;
        OmniGuardTypes.ActionType actionType = OmniGuardTypes.ActionType(actionTypeRaw_);

        if (actionType == OmniGuardTypes.ActionType.HEDGE_TO_STABLE) {
            uint256 hedgeAmount = (pos.volatileCollateralUsdE8 * hedgeBps_) / OmniGuardTypes.BPS_DENOMINATOR;
            pos.volatileCollateralUsdE8 -= hedgeAmount;
            pos.stableReserveUsdE8 += hedgeAmount;
        } else if (actionType == OmniGuardTypes.ActionType.DELEVERAGE_COLLATERAL) {
            uint256 repayTarget = (pos.debtUsdE8 * hedgeBps_) / OmniGuardTypes.BPS_DENOMINATOR;
            uint256 fromStable = repayTarget <= pos.stableReserveUsdE8 ? repayTarget : pos.stableReserveUsdE8;
            pos.stableReserveUsdE8 -= fromStable;
            uint256 remaining = repayTarget - fromStable;
            uint256 fromCollateral =
                remaining <= pos.volatileCollateralUsdE8 ? remaining : pos.volatileCollateralUsdE8;
            pos.volatileCollateralUsdE8 -= fromCollateral;
            pos.debtUsdE8 -= (fromStable + fromCollateral);
        } else if (actionType == OmniGuardTypes.ActionType.CIRCUIT_BREAKER_PAUSE) {
            pos.circuitBreakerActive = true;
            uint256 emergencyShift = (pos.volatileCollateralUsdE8 * hedgeBps_) / OmniGuardTypes.BPS_DENOMINATOR;
            pos.volatileCollateralUsdE8 -= emergencyShift;
            pos.stableReserveUsdE8 += emergencyShift;
        }

        uint64 nowTs = uint64(block.timestamp);
        uint64 latencySec = nowTs >= originTimestamp_ ? nowTs - originTimestamp_ : 0;
        pos.lastActionTimestamp = nowTs;

        uint256 receiptId = receipts.length;
        receipts.push(
            ExecutionReceipt({
                receiptId: receiptId,
                ruleId: ruleId_,
                actionType: actionType,
                marketId: marketId_,
                triggerPriceE8: triggerPriceE8_,
                appliedBps: hedgeBps_,
                aiRiskScoreBps: aiRiskScoreBps_,
                originTimestamp: originTimestamp_,
                callbackTimestamp: nowTs,
                endToEndLatencySec: latencySec,
                originTxHash: originTxHash_,
                collateralBeforeUsdE8: collateralBefore,
                collateralAfterUsdE8: pos.volatileCollateralUsdE8,
                stableAfterUsdE8: pos.stableReserveUsdE8,
                debtAfterUsdE8: pos.debtUsdE8
            })
        );

        emit ProtectionExecuted(
            receiptId,
            ruleId_,
            marketId_,
            actionType,
            triggerPriceE8_,
            hedgeBps_,
            aiRiskScoreBps_,
            originTimestamp_,
            nowTs,
            latencySec,
            originTxHash_
        );
    }

    /**
     * @notice Reactive Omni callback entrypoint for cross-chain price spread rebalancing
     *         (e.g., Base Sepolia 200ms pool vs Unichain Sepolia 1s pool).
     */
    function executeCrossChainRebalance(
        address reactiveSender_,
        uint256 ruleId_,
        bytes32 marketId_,
        uint256 primaryPriceE8_,
        uint256 secondaryPriceE8_,
        uint16 rebalanceBps_,
        uint64 originTimestamp_,
        uint256 originTxHash_
    ) external onlyServiceProvider onlyCallbackSender(reactiveSender_) {
        if (rebalanceBps_ == 0 || rebalanceBps_ > OmniGuardTypes.BPS_DENOMINATOR) {
            revert InvalidBps(rebalanceBps_);
        }
        if (executedOriginTx[originTxHash_][ruleId_]) {
            revert DuplicateCallbackExecution(originTxHash_, ruleId_);
        }
        executedOriginTx[originTxHash_][ruleId_] = true;

        VaultPosition storage pos = positions[marketId_];
        uint256 collateralBefore = pos.volatileCollateralUsdE8;
        uint256 rebalanceAmount = (pos.volatileCollateralUsdE8 * rebalanceBps_) / OmniGuardTypes.BPS_DENOMINATOR;
        pos.volatileCollateralUsdE8 -= rebalanceAmount;
        pos.stableReserveUsdE8 += rebalanceAmount;
        pos.rebalancedVolumeUsdE8 += rebalanceAmount;

        uint256 diff = primaryPriceE8_ >= secondaryPriceE8_
            ? primaryPriceE8_ - secondaryPriceE8_
            : secondaryPriceE8_ - primaryPriceE8_;
        uint256 minPrice = primaryPriceE8_ < secondaryPriceE8_ ? primaryPriceE8_ : secondaryPriceE8_;
        uint256 spreadBps = minPrice > 0 ? (diff * OmniGuardTypes.BPS_DENOMINATOR) / minPrice : 0;

        uint64 nowTs = uint64(block.timestamp);
        uint64 latencySec = nowTs >= originTimestamp_ ? nowTs - originTimestamp_ : 0;
        pos.lastActionTimestamp = nowTs;

        uint256 receiptId = receipts.length;
        receipts.push(
            ExecutionReceipt({
                receiptId: receiptId,
                ruleId: ruleId_,
                actionType: OmniGuardTypes.ActionType.CROSS_CHAIN_REBALANCE,
                marketId: marketId_,
                triggerPriceE8: primaryPriceE8_,
                appliedBps: rebalanceBps_,
                aiRiskScoreBps: 0,
                originTimestamp: originTimestamp_,
                callbackTimestamp: nowTs,
                endToEndLatencySec: latencySec,
                originTxHash: originTxHash_,
                collateralBeforeUsdE8: collateralBefore,
                collateralAfterUsdE8: pos.volatileCollateralUsdE8,
                stableAfterUsdE8: pos.stableReserveUsdE8,
                debtAfterUsdE8: pos.debtUsdE8
            })
        );

        emit CrossChainRebalanced(
            receiptId,
            ruleId_,
            marketId_,
            primaryPriceE8_,
            secondaryPriceE8_,
            spreadBps,
            rebalanceAmount,
            latencySec,
            originTxHash_
        );
    }

    function getReceiptsCount() external view returns (uint256) {
        return receipts.length;
    }

    function getReceipt(uint256 index_) external view returns (ExecutionReceipt memory) {
        return receipts[index_];
    }

    function getPosition(bytes32 marketId_) external view returns (VaultPosition memory) {
        return positions[marketId_];
    }

    /**
     * @notice Computes current vault health factor in bps (e.g., 16666 = 1.6666x; type(uint256).max if zero debt).
     */
    function getHealthFactorBps(bytes32 marketId_) external view returns (uint256) {
        VaultPosition memory pos = positions[marketId_];
        if (pos.debtUsdE8 == 0) return type(uint256).max;
        // Weight volatile collateral at 80% LTV and stable reserve at 95% LTV.
        uint256 effectiveCollateral = (pos.volatileCollateralUsdE8 * 80 + pos.stableReserveUsdE8 * 95) / 100;
        return (effectiveCollateral * OmniGuardTypes.BPS_DENOMINATOR) / pos.debtUsdE8;
    }
}
