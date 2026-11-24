// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { AbstractReactive } from "@reactive/src/base/AbstractReactive.sol";
import { OmniGuardTypes } from "../interfaces/IOmniGuardTypes.sol";

/**
 * @title OmniGuardReactive
 * @notice Autonomous Cross-Chain DeFi Risk Sentinel & Neural Policy Executor deployed on Reactive Lasna (5318007).
 * @dev V2 Security Hardened on Reactive Omni (`reactive-lib-omni`):
 *      - Strict owner + allowlisted rule creator gating on `createRule()` (prevents permissionless vault hijack & lREACT drain).
 *      - Strict destination (chainId, vault) allowlist, hard active rule caps (8/market, 8/vault, 32 total), and swap-and-pop
 *        pruning on deactivation so `react()` always remains far below Lasna's ~900,000 gas ceiling.
 *      - Emergency `pause()` / `unpause()` silences `react()` cleanly without reverting (`ReactiveContractReverted`).
 *      - Strict `RuleKind` <-> `ActionType` validation and cross-chain spread leg freshness window (<= 120s).
 *      - Strict Checks-Effects-Interactions: all state writes and events complete BEFORE `SYSTEM.requestCallbackV_1_0(...)`.
 *      - Strict Unix timestamp cooldowns and deadlines (NEVER `block.number`) for Base Sepolia's 200ms blocks.
 */
contract OmniGuardReactive is AbstractReactive {
    /// @notice Internal queued callback struct enabling strict CEI dispatch outside rule loops.
    struct PendingCallback {
        uint256 chainId;
        address recipient;
        uint64 gasLimit;
        bytes payload;
    }

    /// @notice Legacy system contract on Lasna that emits protocol CRON ticks.
    address internal constant LEGACY_SYSTEM_ADDR = 0x0000000000000000000000000000000000fffFfF;

    uint256 internal constant CRON10_TOPIC_0 = 0x04463f7c1651e6b9774d7f85c85bb94654e3c46ca79b0c16fb16d4183307b687;
    uint256 internal constant CRON100_TOPIC_0 = 0xb49937fb8970e19fd46d48f7e3fb00d659deac0347f79cd7cb542f0fc1503c70;
    uint256 internal constant CRON1000_TOPIC_0 = 0xe20b31294d84c3661ddc8f423abb9c70310d0cf172aa2714ead78029b325e3f4;

    uint256 private constant CRON_INTERVAL_10 = 10;
    uint256 private constant CRON_INTERVAL_100 = 100;
    uint256 private constant CRON_INTERVAL_1000 = 1000;

    uint256 private constant OPCODE_PRICE_UPDATED = 2;
    uint256 private constant OPCODE_THREE_TOPICS = 3;

    uint256 private constant PERCENT_BASE = 100;
    uint256 private constant CASCADE_TIGHTEN_PCT = 65;
    uint256 private constant VOLATILE_TIGHTEN_PCT = 80;
    uint256 private constant ELEVATED_TIGHTEN_PCT = 90;
    uint256 private constant HF_CASCADE_BONUS_BPS = 500;
    uint256 private constant HF_VOLATILE_BONUS_BPS = 250;

    /// @notice Contract administrator.
    address public owner;

    /// @notice Pending administrator for two-step ownership transfer.
    address public pendingOwner;

    /// @notice Emergency global pause switch (silences react() and blocks rule creation).
    bool public paused;

    /// @notice Optional trusted EIP-712 neural signer pin (if non-zero, snapshots from rotated signers are ignored).
    address public trustedNeuralSigner;

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

    /// @notice Total number of currently active rules across all markets and vaults.
    uint256 public activeRulesCount;

    /// @notice Addresses allowlisted by owner to register rules via `createRule()`.
    mapping(address => bool) public authorizedRuleCreators;

    /// @notice Allowlisted destination vaults per destination chain ID.
    mapping(uint256 => mapping(address => bool)) public allowedDestinationVaults;

    /// @notice Registry of all guard rules.
    mapping(uint256 => OmniGuardTypes.GuardRule) public rules;

    /// @notice Active rule IDs indexed by marketId for bounded O(k) evaluation inside `react()`.
    mapping(bytes32 => uint256[]) private _marketRuleIds;

    /// @notice Active rule IDs indexed by monitoredVault address for bounded health factor rescues.
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

    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event PauseStatusChanged(bool paused);
    event RuleCreatorUpdated(address indexed creator, bool allowed);
    event DestinationVaultUpdated(uint256 indexed chainId, address indexed vault, bool allowed);
    event TrustedNeuralSignerUpdated(address indexed previousSigner, address indexed newSigner);
    event NeuralSnapshotCleared(bytes32 indexed marketId);

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
    event StaleSpreadLegSkipped(uint256 indexed ruleId, bytes32 indexed marketId, uint64 primaryTs, uint64 secondaryTs);
    event CronHeartbeatObserved(uint256 reactiveBlockNumber, uint64 reactiveTimestamp);

    error NotOwner();
    error NotPendingOwner();
    error NotAuthorizedRuleCreator(address caller);
    error NotRuleOwner(uint256 ruleId, address caller);
    error ContractPaused();
    error RuleNotFound(uint256 ruleId);
    error InvalidAddress();
    error InvalidChainId();
    error DestinationVaultNotAllowed(uint256 chainId, address vault);
    error RuleCapExceeded(uint256 limit);
    error IncompatibleRuleAction(OmniGuardTypes.RuleKind kind, OmniGuardTypes.ActionType actionType);
    error MissingTriggerCondition(OmniGuardTypes.RuleKind kind);
    error InvalidGasLimit(uint64 provided, uint64 minAllowed, uint64 maxAllowed);
    error InvalidBps(uint256 provided);
    error UnsupportedCronInterval(uint256 interval);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyRuleCreator() {
        if (msg.sender != owner && !authorizedRuleCreators[msg.sender]) {
            revert NotAuthorizedRuleCreator(msg.sender);
        }
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert ContractPaused();
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
        authorizedRuleCreators[owner_] = true;

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

    /// @notice Initiates a two-step ownership transfer.
    function transferOwnership(address newOwner_) external onlyOwner {
        if (newOwner_ == address(0)) revert InvalidAddress();
        pendingOwner = newOwner_;
        emit OwnershipTransferStarted(owner, newOwner_);
    }

    /// @notice Completes a two-step ownership transfer.
    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        address prev = owner;
        owner = pendingOwner;
        pendingOwner = address(0);
        authorizedRuleCreators[owner] = true;
        emit OwnershipTransferred(prev, owner);
    }

    /// @notice Pauses reactive callback dispatch and new rule registrations immediately.
    function pause() external onlyOwner {
        paused = true;
        emit PauseStatusChanged(true);
    }

    /// @notice Resumes reactive callback dispatch and rule registrations.
    function unpause() external onlyOwner {
        paused = false;
        emit PauseStatusChanged(false);
    }

    /// @notice Grants or revokes `createRule()` access for a designated automation operator.
    function setRuleCreator(address creator_, bool allowed_) external onlyOwner {
        if (creator_ == address(0)) revert InvalidAddress();
        authorizedRuleCreators[creator_] = allowed_;
        emit RuleCreatorUpdated(creator_, allowed_);
    }

    /// @notice Allowlists or revokes a destination (chainId, vault) callback target.
    function setAllowedDestinationVault(uint256 chainId_, address vault_, bool allowed_) external onlyOwner {
        if (chainId_ == 0) revert InvalidChainId();
        if (vault_ == address(0)) revert InvalidAddress();
        allowedDestinationVaults[chainId_][vault_] = allowed_;
        emit DestinationVaultUpdated(chainId_, vault_, allowed_);
    }

    /// @notice Pins or rotates the trusted EIP-712 neural signer; prior snapshots from rotated keys are ignored.
    function setTrustedNeuralSigner(address signer_) external onlyOwner {
        if (signer_ == address(0)) revert InvalidAddress();
        address prev = trustedNeuralSigner;
        trustedNeuralSigner = signer_;
        emit TrustedNeuralSignerUpdated(prev, signer_);
    }

    /// @notice Clears a cached neural snapshot on Reactive Lasna (e.g., after key rotation).
    function clearNeuralSnapshot(bytes32 marketId_) external onlyOwner {
        delete latestNeuralByMarket[marketId_];
        emit NeuralSnapshotCleared(marketId_);
    }

    /// @notice Settles any outstanding debt on Reactive Network from this contract's lREACT balance.
    function coverDebt() external onlyOwner {
        _coverDebt();
    }

    /**
     * @notice Subscribes to a secondary origin chain feed (e.g., Unichain Sepolia 1301) for cross-chain spread detection.
     * @dev Follows strict Checks-Effects-Interactions before calling SYSTEM or `_coverDebt()`.
     */
    function setSecondaryOriginFeed(uint256 chainId_, address feed_) external onlyOwner {
        if (chainId_ == 0 || chainId_ == primaryOriginChainId) revert InvalidChainId();
        if (feed_ == address(0)) revert InvalidAddress();

        uint256 oldChainId = secondaryOriginChainId;
        address oldFeed = secondaryOriginFeed;

        // Effects first (CEI)
        secondaryOriginChainId = chainId_;
        secondaryOriginFeed = feed_;
        emit SecondaryOriginFeedUpdated(chainId_, feed_);

        // Interactions last
        if (oldFeed != address(0)) {
            SYSTEM.unsubscribe(
                oldChainId,
                oldFeed,
                OmniGuardTypes.PRICE_UPDATED_TOPIC0,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
        }
        _coverDebt();
        SYSTEM.subscribe(
            chainId_,
            feed_,
            OmniGuardTypes.PRICE_UPDATED_TOPIC0,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
    }

    /// @notice Enables optional Reactive protocol CRON heartbeat subscription (interval: 10, 100, or 1000 blocks).
    function enableCron(uint256 interval_) external onlyOwner {
        uint256 topic0 = _cronTopicFor(interval_);
        bool wasEnabled = cronEnabled;
        uint256 oldTopic0 = activeCronTopic0;

        // Effects first (CEI)
        cronEnabled = true;
        activeCronTopic0 = topic0;
        emit CronSubscriptionUpdated(true, topic0);

        // Interactions last
        if (wasEnabled) {
            SYSTEM.unsubscribe(
                block.chainid,
                LEGACY_SYSTEM_ADDR,
                oldTopic0,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
        }
        _coverDebt();
        SYSTEM.subscribe(
            block.chainid,
            LEGACY_SYSTEM_ADDR,
            topic0,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
    }

    /// @notice Disables protocol CRON subscription to prevent idle lREACT charges.
    function disableCron() external onlyOwner {
        if (!cronEnabled) return;
        uint256 oldTopic0 = activeCronTopic0;

        // Effects first (CEI)
        cronEnabled = false;
        activeCronTopic0 = 0;
        emit CronSubscriptionUpdated(false, oldTopic0);

        // Interactions last
        SYSTEM.unsubscribe(
            block.chainid,
            LEGACY_SYSTEM_ADDR,
            oldTopic0,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
    }

    /**
     * @notice Registers a new autonomous protection or rebalancing rule.
     * @dev Gated to owner or owner-allowlisted creators; destination vault must be allowlisted and active rule caps enforced.
     */
    function createRule(OmniGuardTypes.CreateRuleParams calldata params_)
        external
        onlyRuleCreator
        whenNotPaused
        returns (uint256 ruleId)
    {
        if (params_.destinationChainId == 0) revert InvalidChainId();
        if (params_.destinationVault == address(0)) revert InvalidAddress();
        if (!allowedDestinationVaults[params_.destinationChainId][params_.destinationVault]) {
            revert DestinationVaultNotAllowed(params_.destinationChainId, params_.destinationVault);
        }
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

        _validateRuleAndAction(params_);

        if (activeRulesCount >= OmniGuardTypes.MAX_TOTAL_ACTIVE_RULES) {
            revert RuleCapExceeded(OmniGuardTypes.MAX_TOTAL_ACTIVE_RULES);
        }

        address targetVault = params_.monitoredVault;
        if (params_.kind == OmniGuardTypes.RuleKind.HEALTH_FACTOR_RESCUE) {
            targetVault = params_.monitoredVault == address(0) ? params_.destinationVault : params_.monitoredVault;
            if (_vaultRuleIds[targetVault].length >= OmniGuardTypes.MAX_ACTIVE_RULES_PER_VAULT) {
                revert RuleCapExceeded(OmniGuardTypes.MAX_ACTIVE_RULES_PER_VAULT);
            }
        } else {
            if (_marketRuleIds[params_.marketId].length >= OmniGuardTypes.MAX_ACTIVE_RULES_PER_MARKET) {
                revert RuleCapExceeded(OmniGuardTypes.MAX_ACTIVE_RULES_PER_MARKET);
            }
        }

        ruleId = nextRuleId++;
        activeRulesCount++;

        rules[ruleId] = OmniGuardTypes.GuardRule({
            ruleId: ruleId,
            owner: msg.sender,
            marketId: params_.marketId,
            monitoredVault: targetVault,
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

    /// @notice Activates or deactivates an existing rule, pruning deactivated IDs via swap-and-pop to preserve gas bounds.
    function setRuleActive(uint256 ruleId_, bool active_) external {
        OmniGuardTypes.GuardRule storage rule = rules[ruleId_];
        if (rule.ruleId == 0) revert RuleNotFound(ruleId_);
        if (msg.sender != rule.owner && msg.sender != owner) revert NotRuleOwner(ruleId_, msg.sender);
        if (rule.active == active_) return;

        if (active_) {
            if (!allowedDestinationVaults[rule.destinationChainId][rule.destinationVault]) {
                revert DestinationVaultNotAllowed(rule.destinationChainId, rule.destinationVault);
            }
            if (activeRulesCount >= OmniGuardTypes.MAX_TOTAL_ACTIVE_RULES) {
                revert RuleCapExceeded(OmniGuardTypes.MAX_TOTAL_ACTIVE_RULES);
            }
            if (rule.kind == OmniGuardTypes.RuleKind.HEALTH_FACTOR_RESCUE) {
                if (_vaultRuleIds[rule.monitoredVault].length >= OmniGuardTypes.MAX_ACTIVE_RULES_PER_VAULT) {
                    revert RuleCapExceeded(OmniGuardTypes.MAX_ACTIVE_RULES_PER_VAULT);
                }
                _vaultRuleIds[rule.monitoredVault].push(ruleId_);
            } else {
                if (_marketRuleIds[rule.marketId].length >= OmniGuardTypes.MAX_ACTIVE_RULES_PER_MARKET) {
                    revert RuleCapExceeded(OmniGuardTypes.MAX_ACTIVE_RULES_PER_MARKET);
                }
                _marketRuleIds[rule.marketId].push(ruleId_);
            }
            activeRulesCount++;
            rule.active = true;
        } else {
            rule.active = false;
            activeRulesCount--;
            if (rule.kind == OmniGuardTypes.RuleKind.HEALTH_FACTOR_RESCUE) {
                _removeRuleId(_vaultRuleIds[rule.monitoredVault], ruleId_);
            } else {
                _removeRuleId(_marketRuleIds[rule.marketId], ruleId_);
            }
        }

        emit GuardRuleStatusChanged(ruleId_, active_);
    }

    /// @notice Returns active rule IDs attached to a given marketId.
    function getMarketRuleIds(bytes32 marketId_) external view returns (uint256[] memory) {
        return _marketRuleIds[marketId_];
    }

    /// @notice Returns active rule IDs attached to a given monitoredVault.
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
        if (!_isNeuralSnapshotTrustedAndFresh(snap, referenceTimestamp_)) {
            return (effectiveDrawdownBps, 0);
        }

        activeRiskScoreBps = snap.riskScoreBps;
        if (!rule.adaptiveAiEnabled || effectiveDrawdownBps == 0) {
            return (effectiveDrawdownBps, activeRiskScoreBps);
        }

        if (snap.regime == OmniGuardTypes.RiskRegime.CASCADE_CRITICAL) {
            effectiveDrawdownBps = uint16((uint256(effectiveDrawdownBps) * CASCADE_TIGHTEN_PCT) / PERCENT_BASE);
        } else if (snap.regime == OmniGuardTypes.RiskRegime.VOLATILE) {
            effectiveDrawdownBps = uint16((uint256(effectiveDrawdownBps) * VOLATILE_TIGHTEN_PCT) / PERCENT_BASE);
        } else if (snap.regime == OmniGuardTypes.RiskRegime.ELEVATED) {
            effectiveDrawdownBps = uint16((uint256(effectiveDrawdownBps) * ELEVATED_TIGHTEN_PCT) / PERCENT_BASE);
        }
        if (effectiveDrawdownBps == 0) {
            effectiveDrawdownBps = 1;
        }
    }

    /**
     * @inheritdoc IReactive
     * @notice Invoked exclusively by Reactive Network SYSTEM (`0x8888...8888`) whenever a subscribed event fires.
     * @dev Returns silently when paused or when a log does not match, avoiding `ReactiveContractReverted` gas charges.
     */
    function react(LogRecord calldata log_) external override onlySystem {
        if (paused) return;

        if (log_.topic0 == OmniGuardTypes.PRICE_UPDATED_TOPIC0 && log_.opCode == OPCODE_PRICE_UPDATED) {
            _handlePriceUpdated(log_);
            return;
        }

        if (log_.topic0 == OmniGuardTypes.HEALTH_FACTOR_ALERT_TOPIC0 && log_.opCode == OPCODE_THREE_TOPICS) {
            _handleHealthFactorAlert(log_);
            return;
        }

        if (log_.topic0 == OmniGuardTypes.NEURAL_REGIME_COMMITTED_TOPIC0 && log_.opCode == OPCODE_THREE_TOPICS) {
            _handleNeuralRegimeCommitted(log_);
            return;
        }

        if (cronEnabled && log_.contractAddress == LEGACY_SYSTEM_ADDR && log_.topic0 == activeCronTopic0) {
            totalEventsProcessed++;
            totalCronTicks++;
            lastReactionTimestamp = uint64(block.timestamp);
            emit CronHeartbeatObserved(block.number, uint64(block.timestamp));
            return;
        }

        // Non-matching logs return silently to prevent ReactiveContractReverted gas charges.
    }

    function _handlePriceUpdated(LogRecord calldata log_) internal {
        bool fromPrimary = log_.chainId == primaryOriginChainId && log_.contractAddress == primaryOriginFeed;
        bool fromSecondary = secondaryOriginFeed != address(0) && log_.chainId == secondaryOriginChainId
            && log_.contractAddress == secondaryOriginFeed;
        if (!fromPrimary && !fromSecondary) return;

        bytes32 marketId = bytes32(log_.topic1);
        (uint256 priceE8,, int256 changeBps,, uint64 originTs) =
            abi.decode(log_.data, (uint256, uint256, int256, uint256, uint64));

        totalEventsProcessed++;
        lastReactionTimestamp = uint64(block.timestamp);
        latestPriceByChain[marketId][log_.chainId] = priceE8;
        latestPriceTimestampByChain[marketId][log_.chainId] = originTs;
        lastOriginTimestamp = originTs;

        uint256[] storage ids = _marketRuleIds[marketId];
        uint256 len = ids.length;
        PendingCallback[] memory queue = new PendingCallback[](len);
        uint256 queued = 0;

        for (uint256 i = 0; i < len; ++i) {
            OmniGuardTypes.GuardRule storage rule = rules[ids[i]];
            if (!rule.active) continue;
            if (rule.expiresAt != 0 && originTs > rule.expiresAt) continue;

            if (rule.kind == OmniGuardTypes.RuleKind.STOP_LOSS_HEDGE) {
                (bool shouldDispatch, PendingCallback memory cb) =
                    _evaluateStopLossRule(rule, log_, marketId, priceE8, changeBps, originTs);
                if (shouldDispatch) {
                    queue[queued++] = cb;
                }
            } else if (rule.kind == OmniGuardTypes.RuleKind.CROSS_CHAIN_REBALANCE) {
                (bool shouldDispatch, PendingCallback memory cb) =
                    _evaluateCrossChainSpreadRule(rule, log_, marketId, originTs);
                if (shouldDispatch) {
                    queue[queued++] = cb;
                }
            }
        }

        _flushCallbacks(queue, queued);
    }

    function _evaluateStopLossRule(
        OmniGuardTypes.GuardRule storage rule,
        LogRecord calldata log_,
        bytes32 marketId_,
        uint256 priceE8_,
        int256 changeBps_,
        uint64 originTs_
    ) internal returns (bool shouldDispatch, PendingCallback memory cb) {
        (uint16 effectiveDrawdownBps, uint16 aiRiskScoreBps) = getEffectiveDrawdownBps(rule.ruleId, originTs_);

        bool floorBreached = rule.priceFloorE8 > 0 && priceE8_ <= rule.priceFloorE8;
        bool drawdownBreached =
            effectiveDrawdownBps > 0 && changeBps_ < 0 && uint256(-changeBps_) >= uint256(effectiveDrawdownBps);

        if (!floorBreached && !drawdownBreached) return (false, cb);
        if (!_consumeEligibility(rule, log_, originTs_)) return (false, cb);

        uint16 effectiveHedgeBps = rule.hedgeBps;
        OmniGuardTypes.NeuralSnapshot storage snap = latestNeuralByMarket[marketId_];
        if (
            rule.adaptiveAiEnabled && _isNeuralSnapshotTrustedAndFresh(snap, originTs_)
                && snap.recommendedHedgeBps > effectiveHedgeBps
        ) {
            effectiveHedgeBps = snap.recommendedHedgeBps;
        }

        cb = _prepareProtectionCallback(
            rule, marketId_, priceE8_, effectiveHedgeBps, aiRiskScoreBps, originTs_, log_.txHash, log_.logIndex
        );
        return (true, cb);
    }

    function _evaluateCrossChainSpreadRule(
        OmniGuardTypes.GuardRule storage rule,
        LogRecord calldata log_,
        bytes32 marketId_,
        uint64 originTs_
    ) internal returns (bool shouldDispatch, PendingCallback memory cb) {
        if (secondaryOriginChainId == 0) return (false, cb);

        uint256 primaryPrice = latestPriceByChain[marketId_][primaryOriginChainId];
        uint256 secondaryPrice = latestPriceByChain[marketId_][secondaryOriginChainId];
        if (primaryPrice == 0 || secondaryPrice == 0) return (false, cb);

        uint64 primaryTs = latestPriceTimestampByChain[marketId_][primaryOriginChainId];
        uint64 secondaryTs = latestPriceTimestampByChain[marketId_][secondaryOriginChainId];
        uint64 legSkew = primaryTs >= secondaryTs ? primaryTs - secondaryTs : secondaryTs - primaryTs;
        bool primaryStale = originTs_ > primaryTs && (originTs_ - primaryTs) > OmniGuardTypes.MAX_SPREAD_LEG_AGE_SECONDS;
        bool secondaryStale =
            originTs_ > secondaryTs && (originTs_ - secondaryTs) > OmniGuardTypes.MAX_SPREAD_LEG_AGE_SECONDS;
        if (legSkew > OmniGuardTypes.MAX_SPREAD_LEG_AGE_SECONDS || primaryStale || secondaryStale) {
            emit StaleSpreadLegSkipped(rule.ruleId, marketId_, primaryTs, secondaryTs);
            return (false, cb);
        }

        uint256 diff = primaryPrice >= secondaryPrice ? primaryPrice - secondaryPrice : secondaryPrice - primaryPrice;
        uint256 minPrice = primaryPrice < secondaryPrice ? primaryPrice : secondaryPrice;
        uint256 spreadBps = (diff * OmniGuardTypes.BPS_DENOMINATOR) / minPrice;

        if (spreadBps < rule.spreadThresholdBps) return (false, cb);
        if (!_consumeEligibility(rule, log_, originTs_)) return (false, cb);

        bytes memory payload = abi.encodeWithSignature(
            "executeCrossChainRebalance(address,uint256,bytes32,uint256,uint256,uint16,uint64,uint256,uint256)",
            address(0), // Reserved placeholder: overwritten by Reactive Omni with address(this)
            rule.ruleId,
            marketId_,
            primaryPrice,
            secondaryPrice,
            rule.hedgeBps,
            originTs_,
            log_.txHash,
            log_.logIndex
        );

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

        cb = PendingCallback({
            chainId: rule.destinationChainId,
            recipient: rule.destinationVault,
            gasLimit: rule.callbackGasLimit,
            payload: payload
        });
        return (true, cb);
    }

    function _handleHealthFactorAlert(LogRecord calldata log_) internal {
        if (log_.chainId != primaryOriginChainId || log_.contractAddress != primaryOriginFeed) return;

        address monitoredVault = address(uint160(log_.topic1));
        (uint256 healthFactorBps,,, uint64 originTs) = abi.decode(log_.data, (uint256, uint256, uint256, uint64));

        totalEventsProcessed++;
        lastReactionTimestamp = uint64(block.timestamp);
        lastOriginTimestamp = originTs;

        uint256[] storage ids = _vaultRuleIds[monitoredVault];
        uint256 len = ids.length;
        PendingCallback[] memory queue = new PendingCallback[](len);
        uint256 queued = 0;

        for (uint256 i = 0; i < len; ++i) {
            OmniGuardTypes.GuardRule storage rule = rules[ids[i]];
            if (!rule.active || rule.kind != OmniGuardTypes.RuleKind.HEALTH_FACTOR_RESCUE) continue;
            if (rule.expiresAt != 0 && originTs > rule.expiresAt) continue;

            uint256 effectiveMinHf = rule.minHealthFactorBps;
            uint16 aiRiskScoreBps = 0;
            OmniGuardTypes.NeuralSnapshot storage snap = latestNeuralByMarket[rule.marketId];
            if (rule.adaptiveAiEnabled && _isNeuralSnapshotTrustedAndFresh(snap, originTs)) {
                aiRiskScoreBps = snap.riskScoreBps;
                if (snap.regime == OmniGuardTypes.RiskRegime.CASCADE_CRITICAL) {
                    effectiveMinHf += HF_CASCADE_BONUS_BPS;
                } else if (snap.regime == OmniGuardTypes.RiskRegime.VOLATILE) {
                    effectiveMinHf += HF_VOLATILE_BONUS_BPS;
                }
            }

            if (healthFactorBps > effectiveMinHf) continue;
            if (!_consumeEligibility(rule, log_, originTs)) continue;

            uint256 refPrice = latestPriceByChain[rule.marketId][primaryOriginChainId];
            queue[queued++] = _prepareProtectionCallback(
                rule, rule.marketId, refPrice, rule.hedgeBps, aiRiskScoreBps, originTs, log_.txHash, log_.logIndex
            );
        }

        _flushCallbacks(queue, queued);
    }

    function _handleNeuralRegimeCommitted(LogRecord calldata log_) internal {
        if (log_.chainId != primaryOriginChainId || log_.contractAddress != primaryOriginFeed) return;

        bytes32 marketId = bytes32(log_.topic1);
        address signer = address(uint160(log_.topic2));
        (uint8 regimeRaw, uint16 riskScoreBps, uint16 recommendedHedgeBps, uint64 emittedAt, uint64 validUntil) =
            abi.decode(log_.data, (uint8, uint16, uint16, uint64, uint64));

        if (regimeRaw > uint8(OmniGuardTypes.RiskRegime.CASCADE_CRITICAL)) return;
        if (trustedNeuralSigner != address(0) && signer != trustedNeuralSigner) return;

        OmniGuardTypes.RiskRegime regime = OmniGuardTypes.RiskRegime(regimeRaw);

        totalEventsProcessed++;
        lastReactionTimestamp = uint64(block.timestamp);
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
        PendingCallback[] memory queue = new PendingCallback[](len);
        uint256 queued = 0;

        for (uint256 i = 0; i < len; ++i) {
            OmniGuardTypes.GuardRule storage rule = rules[ids[i]];
            if (!rule.active || rule.kind != OmniGuardTypes.RuleKind.AI_REGIME_ESCALATION) continue;
            if (rule.expiresAt != 0 && emittedAt > rule.expiresAt) continue;

            bool triggered =
                riskScoreBps >= rule.aiRiskThresholdBps || regime == OmniGuardTypes.RiskRegime.CASCADE_CRITICAL;
            if (!triggered) continue;
            if (!_consumeEligibility(rule, log_, emittedAt)) continue;

            uint16 effectiveHedgeBps = recommendedHedgeBps > rule.hedgeBps ? recommendedHedgeBps : rule.hedgeBps;
            queue[queued++] = _prepareProtectionCallback(
                rule, marketId, refPrice, effectiveHedgeBps, riskScoreBps, emittedAt, log_.txHash, log_.logIndex
            );
        }

        _flushCallbacks(queue, queued);
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

    function _prepareProtectionCallback(
        OmniGuardTypes.GuardRule storage rule,
        bytes32 marketId_,
        uint256 triggerPriceE8_,
        uint16 effectiveHedgeBps_,
        uint16 aiRiskScoreBps_,
        uint64 originTs_,
        uint256 originTxHash_,
        uint256 logIndex_
    ) internal returns (PendingCallback memory cb) {
        bytes memory payload = abi.encodeWithSignature(
            "executeProtection(address,uint256,uint8,bytes32,uint256,uint16,uint16,uint64,uint256,uint256)",
            address(0), // Reserved placeholder: overwritten by Reactive Omni with address(this)
            rule.ruleId,
            uint8(rule.actionType),
            marketId_,
            triggerPriceE8_,
            effectiveHedgeBps_,
            aiRiskScoreBps_,
            originTs_,
            originTxHash_,
            logIndex_
        );

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

        cb = PendingCallback({
            chainId: rule.destinationChainId,
            recipient: rule.destinationVault,
            gasLimit: rule.callbackGasLimit,
            payload: payload
        });
    }

    function _flushCallbacks(PendingCallback[] memory queue_, uint256 count_) internal {
        if (count_ == 0) return;

        // Effects completed strictly BEFORE interactions (CEI)
        totalCallbacksRequested += count_;

        for (uint256 i = 0; i < count_; ++i) {
            PendingCallback memory cb = queue_[i];
            SYSTEM.requestCallbackV_1_0(
                ISystemContract.CallbackConfiguration_V_1_0({
                    chainId: cb.chainId,
                    recipient: cb.recipient,
                    gasLimit: cb.gasLimit,
                    payload: cb.payload
                })
            );
        }
    }

    function _validateRuleAndAction(OmniGuardTypes.CreateRuleParams calldata params_) internal pure {
        if (params_.kind == OmniGuardTypes.RuleKind.STOP_LOSS_HEDGE) {
            if (
                params_.actionType != OmniGuardTypes.ActionType.HEDGE_TO_STABLE
                    && params_.actionType != OmniGuardTypes.ActionType.CIRCUIT_BREAKER_PAUSE
            ) {
                revert IncompatibleRuleAction(params_.kind, params_.actionType);
            }
            if (params_.priceFloorE8 == 0 && params_.maxDrawdownBps == 0) {
                revert MissingTriggerCondition(params_.kind);
            }
        } else if (params_.kind == OmniGuardTypes.RuleKind.HEALTH_FACTOR_RESCUE) {
            if (params_.actionType != OmniGuardTypes.ActionType.DELEVERAGE_COLLATERAL) {
                revert IncompatibleRuleAction(params_.kind, params_.actionType);
            }
            if (params_.minHealthFactorBps == 0) {
                revert MissingTriggerCondition(params_.kind);
            }
        } else if (params_.kind == OmniGuardTypes.RuleKind.AI_REGIME_ESCALATION) {
            if (
                params_.actionType != OmniGuardTypes.ActionType.CIRCUIT_BREAKER_PAUSE
                    && params_.actionType != OmniGuardTypes.ActionType.HEDGE_TO_STABLE
            ) {
                revert IncompatibleRuleAction(params_.kind, params_.actionType);
            }
            if (params_.aiRiskThresholdBps == 0) {
                revert MissingTriggerCondition(params_.kind);
            }
        } else if (params_.kind == OmniGuardTypes.RuleKind.CROSS_CHAIN_REBALANCE) {
            if (params_.actionType != OmniGuardTypes.ActionType.CROSS_CHAIN_REBALANCE) {
                revert IncompatibleRuleAction(params_.kind, params_.actionType);
            }
            if (params_.spreadThresholdBps == 0) {
                revert MissingTriggerCondition(params_.kind);
            }
        }
    }

    function _isNeuralSnapshotTrustedAndFresh(OmniGuardTypes.NeuralSnapshot storage snap, uint64 referenceTimestamp_)
        internal
        view
        returns (bool)
    {
        if (snap.signer == address(0) || snap.validUntil < referenceTimestamp_) return false;
        if (trustedNeuralSigner != address(0) && snap.signer != trustedNeuralSigner) return false;
        return true;
    }

    function _removeRuleId(uint256[] storage list_, uint256 ruleId_) internal {
        uint256 len = list_.length;
        for (uint256 i = 0; i < len; ++i) {
            if (list_[i] == ruleId_) {
                list_[i] = list_[len - 1];
                list_.pop();
                return;
            }
        }
    }

    function _cronTopicFor(uint256 interval_) internal pure returns (uint256) {
        if (interval_ == CRON_INTERVAL_10) return CRON10_TOPIC_0;
        if (interval_ == CRON_INTERVAL_100) return CRON100_TOPIC_0;
        if (interval_ == CRON_INTERVAL_1000) return CRON1000_TOPIC_0;
        revert UnsupportedCronInterval(interval_);
    }
}
