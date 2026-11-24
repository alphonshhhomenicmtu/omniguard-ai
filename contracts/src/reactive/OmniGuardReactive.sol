// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { AbstractReactive } from "@reactive/src/base/AbstractReactive.sol";
import { OmniGuardTypes } from "../interfaces/IOmniGuardTypes.sol";

/**
 * @title OmniGuardReactive
 * @notice Autonomous Cross-Chain DeFi Risk Sentinel & Neural Policy Executor deployed on Reactive Lasna (5318007).
 * @dev Built natively on Reactive Omni (`reactive-lib-omni`):
 *      - Uses `SYSTEM` (0x8888888888888888888888888888888888888888) and `onlySystem`.
 *      - Dispatches cross-chain callbacks via `SYSTEM.requestCallbackV_1_0(...)` with `address(0)` as the first
 *        payload parameter for Reactive Network's 160-bit sender authentication injection.
 *      - Enforces STRICT Unix timestamp cooldowns and deadlines (NEVER block.number) for Base Sepolia's 200ms blocks.
 *      - Integrates live EIP-712 Neural Risk Advisements into both adaptive threshold tightening and preemptive escalation.
 *      - Never reverts on non-matching logs inside `react()` to avoid wasted `ReactiveContractReverted` gas charges.
 */
contract OmniGuardReactive is AbstractReactive {
    /// @notice Legacy system contract on Lasna that emits protocol CRON ticks.
    address internal constant LEGACY_SYSTEM_ADDR = 0x0000000000000000000000000000000000fffFfF;

    uint256 internal constant CRON10_TOPIC_0 = 0x04463f7c1651e6b9774d7f85c85bb94654e3c46ca79b0c16fb16d4183307b687;
    uint256 internal constant CRON100_TOPIC_0 = 0xb49937fb8970e19fd46d48f7e3fb00d659deac0347f79cd7cb542f0fc1503c70;
    uint256 internal constant CRON1000_TOPIC_0 = 0xe20b31294d84c3661ddc8f423abb9c70310d0cf172aa2714ead78029b325e3f4;

    /// @notice Contract administrator (also authorized to configure feeds & rules).
    address public owner;

    /// @notice Primary origin chain ID (e.g., 84532 for Base Sepolia).
    uint256 public immutable primaryOriginChainId;

    /// @notice Primary origin market feed address on primaryOriginChainId.
    address public immutable primaryOriginFeed;

    /// @notice Optional secondary origin chain ID (e.g., 1301 for Unichain Sepolia) for cross-chain spread rebalancing.
    uint256 public secondaryOriginChainId;

    /// @notice Optional secondary origin market feed address.
    address public secondaryOriginFeed;

    /// @notice Whether optional CRON heartbeat subscription is active.
    bool public cronEnabled;

    /// @notice Active CRON topic0 when cronEnabled is true.
    uint256 public activeCronTopic0;

    /// @notice Incrementing guard rule identifier.
    uint256 public nextRuleId = 1;

    /// @notice Registry of all guard rules.
    mapping(uint256 => OmniGuardTypes.GuardRule) public rules;

    /// @notice Rule IDs indexed by marketId for O(k) evaluation inside `react()`.
    mapping(bytes32 => uint256[]) private _marketRuleIds;

    /// @notice Rule IDs indexed by monitoredVault address for health factor rescues.
    mapping(address => uint256[]) private _vaultRuleIds;

    /// @notice Latest neural risk snapshot received per marketId.
    mapping(bytes32 => OmniGuardTypes.NeuralSnapshot) public latestNeuralByMarket;

    /// @notice Latest observed price per (marketId, chainId) for cross-chain spread detection.
    mapping(bytes32 => mapping(uint256 => uint256)) public latestPriceByChain;

    /// @notice Latest observed timestamp per (marketId, chainId).
    mapping(bytes32 => mapping(uint256 => uint64)) public latestPriceTimestampByChain;

    /// @notice Replay/idempotency guard per (originChain, txHash, logIndex, ruleId).
    mapping(bytes32 => bool) public processedEventRules;

    /// @notice Telemetry counters for live latency & activity monitoring.
    uint256 public totalEventsProcessed;
    uint256 public totalCallbacksRequested;
    uint256 public totalNeuralUpdates;
    uint256 public totalCronTicks;
    uint64 public lastReactionTimestamp;
    uint64 public lastOriginTimestamp;

    event GuardRuleCreated(
        uint256 indexed ruleId,
        address indexed ruleOwner,
        bytes32 indexed marketId,
        uint256 destinationChainId,
        address destinationVault,
        OmniGuardTypes.RuleKind kind,
        uint64 cooldownSeconds
    );

    event GuardRuleStatusChanged(uint256 indexed ruleId, bool active);
    event SecondaryOriginFeedUpdated(uint256 indexed chainId, address indexed feed);
    event CronSubscriptionUpdated(bool enabled, uint256 topic0);

    event NeuralSnapshotSynchronized(
        bytes32 indexed marketId,
        OmniGuardTypes.RiskRegime regime,
        uint16 riskScoreBps,
        uint16 recommendedHedgeBps,
        uint64 emittedAt,
        uint64 validUntil
    );

    event ReactionDispatched(
        uint256 indexed ruleId,
        uint256 indexed destinationChainId,
        address indexed destinationVault,
        OmniGuardTypes.RuleKind kind,
        OmniGuardTypes.ActionType actionType,
        uint16 effectiveHedgeBps,
        uint16 aiRiskScoreBps,
        uint64 originTimestamp,
        uint64 reactiveTimestamp,
        uint256 originTxHash
    );

    event CooldownSkipped(uint256 indexed ruleId, uint64 originTimestamp, uint64 nextEligibleAt);
    event CronHeartbeatObserved(uint256 reactiveBlockNumber, uint64 reactiveTimestamp);

    error NotOwner();
    error NotRuleOwner(uint256 ruleId, address caller);
    error RuleNotFound(uint256 ruleId);
    error InvalidAddress();
    error InvalidChainId();
    error InvalidGasLimit(uint64 provided, uint64 minAllowed, uint64 maxAllowed);
    error InvalidBps(uint256 provided);
    error UnsupportedCronInterval(uint256 interval);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /**
     * @notice Payable constructor so lREACT operating funds can be supplied at deployment.
     * @param primaryOriginChainId_ Primary origin chain ID (e.g., 84532 for Base Sepolia).
     * @param primaryOriginFeed_ Deployed OmniMarketFeed address on primaryOriginChainId_.
     * @param owner_ Contract administrator address.
     */
    constructor(uint256 primaryOriginChainId_, address primaryOriginFeed_, address owner_) payable {
        if (primaryOriginChainId_ == 0) revert InvalidChainId();
        if (primaryOriginFeed_ == address(0) || owner_ == address(0)) revert InvalidAddress();

        primaryOriginChainId = primaryOriginChainId_;
        primaryOriginFeed = primaryOriginFeed_;
        owner = owner_;

        // Subscribe to all three core origin events on the primary origin chain via Reactive Omni SYSTEM.
        SYSTEM.subscribe(
            primaryOriginChainId_,
            primaryOriginFeed_,
            OmniGuardTypes.PRICE_UPDATED_TOPIC0,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
        SYSTEM.subscribe(
            primaryOriginChainId_,
            primaryOriginFeed_,
            OmniGuardTypes.HEALTH_FACTOR_ALERT_TOPIC0,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
        SYSTEM.subscribe(
            primaryOriginChainId_,
            primaryOriginFeed_,
            OmniGuardTypes.NEURAL_REGIME_COMMITTED_TOPIC0,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
    }

    /// @notice Settles any outstanding debt on Reactive Network from this contract's lREACT balance.
    function coverDebt() external {
        _coverDebt();
    }

    /**
     * @notice Subscribes to a secondary origin chain feed (e.g., Unichain Sepolia 1301) for cross-chain spread detection.
     */
    function setSecondaryOriginFeed(uint256 chainId_, address feed_) external onlyOwner {
        if (chainId_ == 0 || chainId_ == primaryOriginChainId) revert InvalidChainId();
        if (feed_ == address(0)) revert InvalidAddress();

        if (secondaryOriginFeed != address(0)) {
            SYSTEM.unsubscribe(
                secondaryOriginChainId,
                secondaryOriginFeed,
                OmniGuardTypes.PRICE_UPDATED_TOPIC0,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
        }

        secondaryOriginChainId = chainId_;
        secondaryOriginFeed = feed_;

        _coverDebt();
        SYSTEM.subscribe(
            chainId_,
            feed_,
            OmniGuardTypes.PRICE_UPDATED_TOPIC0,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );

        emit SecondaryOriginFeedUpdated(chainId_, feed_);
    }

    /// @notice Enables optional Reactive protocol CRON heartbeat subscription (interval: 10, 100, or 1000 blocks).
    function enableCron(uint256 interval_) external onlyOwner {
        uint256 topic0 = _cronTopicFor(interval_);
        if (cronEnabled) {
            SYSTEM.unsubscribe(
                block.chainid,
                LEGACY_SYSTEM_ADDR,
                activeCronTopic0,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
        }
        _coverDebt();
        cronEnabled = true;
        activeCronTopic0 = topic0;
        SYSTEM.subscribe(
            block.chainid,
            LEGACY_SYSTEM_ADDR,
            topic0,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
        emit CronSubscriptionUpdated(true, topic0);
    }

    /// @notice Disables protocol CRON subscription to prevent idle lREACT charges.
    function disableCron() external onlyOwner {
        if (!cronEnabled) return;
        uint256 oldTopic0 = activeCronTopic0;
        cronEnabled = false;
        activeCronTopic0 = 0;
        SYSTEM.unsubscribe(
            block.chainid,
            LEGACY_SYSTEM_ADDR,
            oldTopic0,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
        emit CronSubscriptionUpdated(false, oldTopic0);
    }

    /**
     * @notice Registers a new autonomous protection or rebalancing rule.
     * @dev Can be authored directly via natural-language compilation in the OmniGuard AI dashboard.
     */
    function createRule(OmniGuardTypes.CreateRuleParams calldata params_) external returns (uint256 ruleId) {
        if (params_.destinationChainId == 0) revert InvalidChainId();
        if (params_.destinationVault == address(0)) revert InvalidAddress();
        if (
            params_.callbackGasLimit < OmniGuardTypes.MIN_CALLBACK_GAS_LIMIT
                || params_.callbackGasLimit > OmniGuardTypes.MAX_CALLBACK_GAS_LIMIT
        ) {
            revert InvalidGasLimit(
                params_.callbackGasLimit,
                OmniGuardTypes.MIN_CALLBACK_GAS_LIMIT,
                OmniGuardTypes.MAX_CALLBACK_GAS_LIMIT
            );
        }
        if (
            params_.maxDrawdownBps > OmniGuardTypes.BPS_DENOMINATOR
                || params_.aiRiskThresholdBps > OmniGuardTypes.BPS_DENOMINATOR
                || params_.spreadThresholdBps > OmniGuardTypes.BPS_DENOMINATOR
                || params_.hedgeBps == 0 || params_.hedgeBps > OmniGuardTypes.BPS_DENOMINATOR
        ) {
            revert InvalidBps(params_.hedgeBps);
        }

        ruleId = nextRuleId++;
        rules[ruleId] = OmniGuardTypes.GuardRule({
            ruleId: ruleId,
            owner: msg.sender,
            marketId: params_.marketId,
            monitoredVault: params_.monitoredVault,
            destinationChainId: params_.destinationChainId,
            destinationVault: params_.destinationVault,
            kind: params_.kind,
            actionType: params_.actionType,
            priceFloorE8: params_.priceFloorE8,
            maxDrawdownBps: params_.maxDrawdownBps,
            minHealthFactorBps: params_.minHealthFactorBps,
            aiRiskThresholdBps: params_.aiRiskThresholdBps,
            spreadThresholdBps: params_.spreadThresholdBps,
            hedgeBps: params_.hedgeBps,
            cooldownSeconds: params_.cooldownSeconds,
            lastTriggeredAt: 0,
            expiresAt: params_.expiresAt,
            callbackGasLimit: params_.callbackGasLimit,
            adaptiveAiEnabled: params_.adaptiveAiEnabled,
            active: true
        });

        if (params_.kind == OmniGuardTypes.RuleKind.HEALTH_FACTOR_RESCUE) {
            address targetVault = params_.monitoredVault == address(0) ? params_.destinationVault : params_.monitoredVault;
            rules[ruleId].monitoredVault = targetVault;
            _vaultRuleIds[targetVault].push(ruleId);
        } else {
            _marketRuleIds[params_.marketId].push(ruleId);
        }

        emit GuardRuleCreated(
            ruleId,
            msg.sender,
            params_.marketId,
            params_.destinationChainId,
            params_.destinationVault,
            params_.kind,
            params_.cooldownSeconds
        );
    }

    /// @notice Activates or pauses an existing rule.
    function setRuleActive(uint256 ruleId_, bool active_) external {
        OmniGuardTypes.GuardRule storage rule = rules[ruleId_];
        if (rule.ruleId == 0) revert RuleNotFound(ruleId_);
        if (msg.sender != rule.owner && msg.sender != owner) revert NotRuleOwner(ruleId_, msg.sender);
        rule.active = active_;
        emit GuardRuleStatusChanged(ruleId_, active_);
    }

    /// @notice Returns rule IDs attached to a given marketId.
    function getMarketRuleIds(bytes32 marketId_) external view returns (uint256[] memory) {
        return _marketRuleIds[marketId_];
    }

    /// @notice Returns rule IDs attached to a given monitoredVault.
    function getVaultRuleIds(address vault_) external view returns (uint256[] memory) {
        return _vaultRuleIds[vault_];
    }

    /// @notice Returns the effective drawdown threshold for a rule after neural regime adjustment.
    function getEffectiveDrawdownBps(uint256 ruleId_, uint64 referenceTimestamp_)
        public
        view
        returns (uint16 effectiveDrawdownBps, uint16 activeRiskScoreBps)
    {
        OmniGuardTypes.GuardRule storage rule = rules[ruleId_];
        effectiveDrawdownBps = rule.maxDrawdownBps;

        OmniGuardTypes.NeuralSnapshot storage snap = latestNeuralByMarket[rule.marketId];
        bool neuralFresh = snap.signer != address(0) && snap.validUntil >= referenceTimestamp_;
        if (!neuralFresh) {
            return (effectiveDrawdownBps, 0);
        }

        activeRiskScoreBps = snap.riskScoreBps;
        if (!rule.adaptiveAiEnabled || effectiveDrawdownBps == 0) {
            return (effectiveDrawdownBps, activeRiskScoreBps);
        }

        // Tighten drawdown tolerance dynamically under elevated neural risk regimes:
        // VOLATILE -> 80% of base threshold (20% tighter)
        // CASCADE_CRITICAL -> 65% of base threshold (35% tighter)
        if (snap.regime == OmniGuardTypes.RiskRegime.CASCADE_CRITICAL) {
            effectiveDrawdownBps = uint16((uint256(effectiveDrawdownBps) * 65) / 100);
        } else if (snap.regime == OmniGuardTypes.RiskRegime.VOLATILE) {
            effectiveDrawdownBps = uint16((uint256(effectiveDrawdownBps) * 80) / 100);
        } else if (snap.regime == OmniGuardTypes.RiskRegime.ELEVATED) {
            effectiveDrawdownBps = uint16((uint256(effectiveDrawdownBps) * 90) / 100);
        }
        if (effectiveDrawdownBps == 0) {
            effectiveDrawdownBps = 1;
        }
    }

    /**
     * @inheritdoc IReactive
     * @notice Invoked exclusively by Reactive Network SYSTEM (`0x8888...8888`) whenever a subscribed event fires.
     * @dev Strictly validates `opCode` before decoding `log_.data`, never reverts on non-matching logs,
     *      and enforces timestamp-only cooldowns & deadlines.
     */
    function react(LogRecord calldata log_) external override onlySystem {
        totalEventsProcessed++;
        lastReactionTimestamp = uint64(block.timestamp);

        if (log_.topic0 == OmniGuardTypes.PRICE_UPDATED_TOPIC0 && log_.opCode == 2) {
            _handlePriceUpdated(log_);
            return;
        }

        if (log_.topic0 == OmniGuardTypes.HEALTH_FACTOR_ALERT_TOPIC0 && log_.opCode == 3) {
            _handleHealthFactorAlert(log_);
            return;
        }

        if (log_.topic0 == OmniGuardTypes.NEURAL_REGIME_COMMITTED_TOPIC0 && log_.opCode == 3) {
            _handleNeuralRegimeCommitted(log_);
            return;
        }

        if (cronEnabled && log_.contractAddress == LEGACY_SYSTEM_ADDR && log_.topic0 == activeCronTopic0) {
            totalCronTicks++;
            emit CronHeartbeatObserved(block.number, uint64(block.timestamp));
            return;
        }

        // Non-matching logs return silently to prevent ReactiveContractReverted gas charges.
    }

    function _handlePriceUpdated(LogRecord calldata log_) internal {
        // Authenticate origin contract source.
        bool fromPrimary = log_.chainId == primaryOriginChainId && log_.contractAddress == primaryOriginFeed;
        bool fromSecondary = secondaryOriginFeed != address(0) && log_.chainId == secondaryOriginChainId
            && log_.contractAddress == secondaryOriginFeed;
        if (!fromPrimary && !fromSecondary) return;

        bytes32 marketId = bytes32(log_.topic1);
        (uint256 priceE8,, int256 changeBps,, uint64 originTs) =
            abi.decode(log_.data, (uint256, uint256, int256, uint256, uint64));

        latestPriceByChain[marketId][log_.chainId] = priceE8;
        latestPriceTimestampByChain[marketId][log_.chainId] = originTs;
        lastOriginTimestamp = originTs;

        uint256[] storage ids = _marketRuleIds[marketId];
        uint256 len = ids.length;

        for (uint256 i = 0; i < len; ++i) {
            OmniGuardTypes.GuardRule storage rule = rules[ids[i]];
            if (!rule.active) continue;
            if (rule.expiresAt != 0 && originTs > rule.expiresAt) continue;

            if (rule.kind == OmniGuardTypes.RuleKind.STOP_LOSS_HEDGE) {
                _evaluateStopLossRule(rule, log_, marketId, priceE8, changeBps, originTs);
            } else if (rule.kind == OmniGuardTypes.RuleKind.CROSS_CHAIN_REBALANCE) {
                _evaluateCrossChainSpreadRule(rule, log_, marketId, originTs);
            }
        }
    }

    function _evaluateStopLossRule(
        OmniGuardTypes.GuardRule storage rule,
        LogRecord calldata log_,
        bytes32 marketId_,
        uint256 priceE8_,
        int256 changeBps_,
        uint64 originTs_
    ) internal {
        (uint16 effectiveDrawdownBps, uint16 aiRiskScoreBps) = getEffectiveDrawdownBps(rule.ruleId, originTs_);

        bool floorBreached = rule.priceFloorE8 > 0 && priceE8_ <= rule.priceFloorE8;
        bool drawdownBreached =
            effectiveDrawdownBps > 0 && changeBps_ < 0 && uint256(-changeBps_) >= uint256(effectiveDrawdownBps);

        if (!floorBreached && !drawdownBreached) return;
        if (!_consumeEligibility(rule, log_, originTs_)) return;

        uint16 effectiveHedgeBps = rule.hedgeBps;
        OmniGuardTypes.NeuralSnapshot storage snap = latestNeuralByMarket[marketId_];
        if (
            rule.adaptiveAiEnabled && snap.signer != address(0) && snap.validUntil >= originTs_
                && snap.recommendedHedgeBps > effectiveHedgeBps
        ) {
            effectiveHedgeBps = snap.recommendedHedgeBps;
        }

        _dispatchProtectionCallback(
            rule, marketId_, priceE8_, effectiveHedgeBps, aiRiskScoreBps, originTs_, log_.txHash
        );
    }

    function _evaluateCrossChainSpreadRule(
        OmniGuardTypes.GuardRule storage rule,
        LogRecord calldata log_,
        bytes32 marketId_,
        uint64 originTs_
    ) internal {
        if (secondaryOriginChainId == 0) return;

        uint256 primaryPrice = latestPriceByChain[marketId_][primaryOriginChainId];
        uint256 secondaryPrice = latestPriceByChain[marketId_][secondaryOriginChainId];
        if (primaryPrice == 0 || secondaryPrice == 0) return;

        uint256 diff = primaryPrice >= secondaryPrice ? primaryPrice - secondaryPrice : secondaryPrice - primaryPrice;
        uint256 minPrice = primaryPrice < secondaryPrice ? primaryPrice : secondaryPrice;
        uint256 spreadBps = (diff * OmniGuardTypes.BPS_DENOMINATOR) / minPrice;

        if (spreadBps < rule.spreadThresholdBps) return;
        if (!_consumeEligibility(rule, log_, originTs_)) return;

        bytes memory payload = abi.encodeWithSignature(
            "executeCrossChainRebalance(address,uint256,bytes32,uint256,uint256,uint16,uint64,uint256)",
            address(0), // Reserved placeholder: overwritten by Reactive Omni with address(this)
            rule.ruleId,
            marketId_,
            primaryPrice,
            secondaryPrice,
            rule.hedgeBps,
            originTs_,
            log_.txHash
        );

        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: rule.destinationChainId,
                recipient: rule.destinationVault,
                gasLimit: rule.callbackGasLimit,
                payload: payload
            })
        );

        totalCallbacksRequested++;
        emit ReactionDispatched(
            rule.ruleId,
            rule.destinationChainId,
            rule.destinationVault,
            rule.kind,
            OmniGuardTypes.ActionType.CROSS_CHAIN_REBALANCE,
            rule.hedgeBps,
            0,
            originTs_,
            uint64(block.timestamp),
            log_.txHash
        );
    }

    function _handleHealthFactorAlert(LogRecord calldata log_) internal {
        if (log_.chainId != primaryOriginChainId || log_.contractAddress != primaryOriginFeed) return;

        address monitoredVault = address(uint160(log_.topic1));
        (uint256 healthFactorBps,,, uint64 originTs) = abi.decode(log_.data, (uint256, uint256, uint256, uint64));
        lastOriginTimestamp = originTs;

        uint256[] storage ids = _vaultRuleIds[monitoredVault];
        uint256 len = ids.length;

        for (uint256 i = 0; i < len; ++i) {
            OmniGuardTypes.GuardRule storage rule = rules[ids[i]];
            if (!rule.active || rule.kind != OmniGuardTypes.RuleKind.HEALTH_FACTOR_RESCUE) continue;
            if (rule.expiresAt != 0 && originTs > rule.expiresAt) continue;

            uint256 effectiveMinHf = rule.minHealthFactorBps;
            uint16 aiRiskScoreBps = 0;
            OmniGuardTypes.NeuralSnapshot storage snap = latestNeuralByMarket[rule.marketId];
            if (rule.adaptiveAiEnabled && snap.signer != address(0) && snap.validUntil >= originTs) {
                aiRiskScoreBps = snap.riskScoreBps;
                // In critical neural regimes, rescue earlier (raise minimum safe HF by +500 bps = +0.05x).
                if (snap.regime == OmniGuardTypes.RiskRegime.CASCADE_CRITICAL) {
                    effectiveMinHf += 500;
                } else if (snap.regime == OmniGuardTypes.RiskRegime.VOLATILE) {
                    effectiveMinHf += 250;
                }
            }

            if (healthFactorBps > effectiveMinHf) continue;
            if (!_consumeEligibility(rule, log_, originTs)) continue;

            uint256 refPrice = latestPriceByChain[rule.marketId][primaryOriginChainId];
            _dispatchProtectionCallback(
                rule, rule.marketId, refPrice, rule.hedgeBps, aiRiskScoreBps, originTs, log_.txHash
            );
        }
    }

    function _handleNeuralRegimeCommitted(LogRecord calldata log_) internal {
        if (log_.chainId != primaryOriginChainId || log_.contractAddress != primaryOriginFeed) return;

        bytes32 marketId = bytes32(log_.topic1);
        address signer = address(uint160(log_.topic2));
        (uint8 regimeRaw, uint16 riskScoreBps, uint16 recommendedHedgeBps, uint64 emittedAt, uint64 validUntil) =
            abi.decode(log_.data, (uint8, uint16, uint16, uint64, uint64));

        if (regimeRaw > uint8(OmniGuardTypes.RiskRegime.CASCADE_CRITICAL)) return;
        OmniGuardTypes.RiskRegime regime = OmniGuardTypes.RiskRegime(regimeRaw);

        latestNeuralByMarket[marketId] = OmniGuardTypes.NeuralSnapshot({
            regime: regime,
            riskScoreBps: riskScoreBps,
            recommendedHedgeBps: recommendedHedgeBps,
            emittedAt: emittedAt,
            validUntil: validUntil,
            signer: signer
        });

        totalNeuralUpdates++;
        lastOriginTimestamp = emittedAt;
        emit NeuralSnapshotSynchronized(marketId, regime, riskScoreBps, recommendedHedgeBps, emittedAt, validUntil);

        uint256[] storage ids = _marketRuleIds[marketId];
        uint256 len = ids.length;
        uint256 refPrice = latestPriceByChain[marketId][primaryOriginChainId];

        for (uint256 i = 0; i < len; ++i) {
            OmniGuardTypes.GuardRule storage rule = rules[ids[i]];
            if (!rule.active || rule.kind != OmniGuardTypes.RuleKind.AI_REGIME_ESCALATION) continue;
            if (rule.expiresAt != 0 && emittedAt > rule.expiresAt) continue;

            bool triggered =
                riskScoreBps >= rule.aiRiskThresholdBps || regime == OmniGuardTypes.RiskRegime.CASCADE_CRITICAL;
            if (!triggered) continue;
            if (!_consumeEligibility(rule, log_, emittedAt)) continue;

            uint16 effectiveHedgeBps = recommendedHedgeBps > rule.hedgeBps ? recommendedHedgeBps : rule.hedgeBps;
            _dispatchProtectionCallback(
                rule, marketId, refPrice, effectiveHedgeBps, riskScoreBps, emittedAt, log_.txHash
            );
        }
    }

    function _consumeEligibility(OmniGuardTypes.GuardRule storage rule, LogRecord calldata log_, uint64 originTs_)
        internal
        returns (bool)
    {
        // Strict Unix timestamp cooldown check (never block.number).
        if (rule.lastTriggeredAt != 0 && rule.cooldownSeconds > 0) {
            uint64 nextEligibleAt = rule.lastTriggeredAt + rule.cooldownSeconds;
            if (originTs_ < nextEligibleAt) {
                emit CooldownSkipped(rule.ruleId, originTs_, nextEligibleAt);
                return false;
            }
        }

        bytes32 eventKey = keccak256(abi.encode(log_.chainId, log_.txHash, log_.logIndex, rule.ruleId));
        if (processedEventRules[eventKey]) return false;

        processedEventRules[eventKey] = true;
        rule.lastTriggeredAt = originTs_;
        return true;
    }

    function _dispatchProtectionCallback(
        OmniGuardTypes.GuardRule storage rule,
        bytes32 marketId_,
        uint256 triggerPriceE8_,
        uint16 effectiveHedgeBps_,
        uint16 aiRiskScoreBps_,
        uint64 originTs_,
        uint256 originTxHash_
    ) internal {
        bytes memory payload = abi.encodeWithSignature(
            "executeProtection(address,uint256,uint8,bytes32,uint256,uint16,uint16,uint64,uint256)",
            address(0), // Reserved placeholder: overwritten by Reactive Omni with address(this)
            rule.ruleId,
            uint8(rule.actionType),
            marketId_,
            triggerPriceE8_,
            effectiveHedgeBps_,
            aiRiskScoreBps_,
            originTs_,
            originTxHash_
        );

        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: rule.destinationChainId,
                recipient: rule.destinationVault,
                gasLimit: rule.callbackGasLimit,
                payload: payload
            })
        );

        totalCallbacksRequested++;
        emit ReactionDispatched(
            rule.ruleId,
            rule.destinationChainId,
            rule.destinationVault,
            rule.kind,
            rule.actionType,
            effectiveHedgeBps_,
            aiRiskScoreBps_,
            originTs_,
            uint64(block.timestamp),
            originTxHash_
        );
    }

    function _cronTopicFor(uint256 interval_) internal pure returns (uint256) {
        if (interval_ == 10) return CRON10_TOPIC_0;
        if (interval_ == 100) return CRON100_TOPIC_0;
        if (interval_ == 1000) return CRON1000_TOPIC_0;
        revert UnsupportedCronInterval(interval_);
    }
}
