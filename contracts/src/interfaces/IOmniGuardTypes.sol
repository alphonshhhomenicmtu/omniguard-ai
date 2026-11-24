// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/**
 * @title IOmniGuardTypes
 * @notice Shared enums, structs, and canonical event topic0 constants for OmniGuard AI
 *         across Origin chains (Base Sepolia / Unichain Sepolia), Reactive Lasna, and Destination vaults.
 * @dev All cooldowns, expirations, and latency windows strictly use Unix timestamps (uint64 seconds),
 *      never block numbers, in compliance with Base Sepolia's 200ms Denim block cadence.
 */
library OmniGuardTypes {
    /// @notice Neural Risk Sentinel classification regimes.
    enum RiskRegime {
        CALM,
        ELEVATED,
        VOLATILE,
        CASCADE_CRITICAL
    }

    /// @notice Guard rule trigger categories supported by OmniGuardReactive.
    enum RuleKind {
        STOP_LOSS_HEDGE,
        HEALTH_FACTOR_RESCUE,
        AI_REGIME_ESCALATION,
        CROSS_CHAIN_REBALANCE
    }

    /// @notice Protective action executed on the destination OmniGuardVault via Reactive callback.
    enum ActionType {
        HEDGE_TO_STABLE,
        DELEVERAGE_COLLATERAL,
        CIRCUIT_BREAKER_PAUSE,
        CROSS_CHAIN_REBALANCE
    }

    /// @notice On-chain policy rule stored in OmniGuardReactive on Reactive Lasna.
    struct GuardRule {
        uint256 ruleId;
        address owner;
        bytes32 marketId;
        address monitoredVault;
        uint256 destinationChainId;
        address destinationVault;
        RuleKind kind;
        ActionType actionType;
        uint256 priceFloorE8;
        uint16 maxDrawdownBps;
        uint16 minHealthFactorBps;
        uint16 aiRiskThresholdBps;
        uint16 spreadThresholdBps;
        uint16 hedgeBps;
        uint64 cooldownSeconds;
        uint64 lastTriggeredAt;
        uint64 expiresAt;
        uint64 callbackGasLimit;
        bool adaptiveAiEnabled;
        bool active;
    }

    /// @notice Input parameters for creating a new guard rule.
    struct CreateRuleParams {
        bytes32 marketId;
        address monitoredVault;
        uint256 destinationChainId;
        address destinationVault;
        RuleKind kind;
        ActionType actionType;
        uint256 priceFloorE8;
        uint16 maxDrawdownBps;
        uint16 minHealthFactorBps;
        uint16 aiRiskThresholdBps;
        uint16 spreadThresholdBps;
        uint16 hedgeBps;
        uint64 cooldownSeconds;
        uint64 expiresAt;
        uint64 callbackGasLimit;
        bool adaptiveAiEnabled;
    }

    /// @notice Latest neural regime state synchronized onto Reactive Lasna from origin EIP-712 advisements.
    struct NeuralSnapshot {
        RiskRegime regime;
        uint16 riskScoreBps;
        uint16 recommendedHedgeBps;
        uint64 emittedAt;
        uint64 validUntil;
        address signer;
    }

    /// @notice Basis points denominator (100.00%).
    uint16 internal constant BPS_DENOMINATOR = 10_000;

    /// @notice Minimum safe callback gas limit on Base Sepolia / Unichain Sepolia Omni proxies
    ///         (accounts for 80,000 _extraGas + 50,000 _maxChargeGas + callback execution headroom).
    uint64 internal constant MIN_CALLBACK_GAS_LIMIT = 250_000;

    /// @notice Maximum allowed callback gas limit per rule.
    uint64 internal constant MAX_CALLBACK_GAS_LIMIT = 2_000_000;

    /// @notice Canonical topic0 hash for OmniMarketFeed.PriceUpdated.
    uint256 internal constant PRICE_UPDATED_TOPIC0 =
        uint256(keccak256("PriceUpdated(bytes32,uint256,uint256,int256,uint256,uint64)"));

    /// @notice Canonical topic0 hash for OmniMarketFeed.HealthFactorAlert.
    uint256 internal constant HEALTH_FACTOR_ALERT_TOPIC0 =
        uint256(keccak256("HealthFactorAlert(address,address,uint256,uint256,uint256,uint64)"));

    /// @notice Canonical topic0 hash for OmniMarketFeed.NeuralRegimeCommitted.
    uint256 internal constant NEURAL_REGIME_COMMITTED_TOPIC0 =
        uint256(keccak256("NeuralRegimeCommitted(bytes32,address,uint8,uint16,uint16,uint64,uint64)"));

    /// @notice Standard market identifier for WETH/USDC.
    bytes32 internal constant MARKET_WETH_USDC = keccak256("WETH/USDC");

    /// @notice Standard market identifier for WBTC/USDC.
    bytes32 internal constant MARKET_WBTC_USDC = keccak256("WBTC/USDC");
}
