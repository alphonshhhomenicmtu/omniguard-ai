// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import { OmniGuardTypes } from "../interfaces/IOmniGuardTypes.sol";

/**
 * @title OmniMarketFeed
 * @notice Origin-chain market telemetry, vault health feed, and EIP-712 Neural Advisement verifier (V2 hardened).
 * @dev Deployed on Base Sepolia (84532, 200ms blocks) and/or Unichain Sepolia (1301, 1s blocks).
 *      Emits structured events consumed in ~1s by OmniGuardReactive on Reactive Lasna (5318007).
 *      Enforces bounded EIP-712 TTLs (<= 180s), issuedAt skew guards (<= 120s), two-step ownership,
 *      and signer-rotation snapshot invalidation using Unix timestamps exclusively (never block.number).
 */
contract OmniMarketFeed {
    /// @notice Market state snapshot tracked on the origin chain.
    struct MarketState {
        uint256 lastPriceE8;
        uint256 lastVolatilityBps;
        uint64 lastUpdatedAt;
    }

    /// @notice EIP-712 signed neural advisement payload submitted by the running Neural Sentinel.
    struct NeuralAdvisement {
        bytes32 marketId;
        uint8 regime;
        uint16 riskScoreBps;
        uint16 recommendedHedgeBps;
        uint64 issuedAt;
        uint64 validUntil;
        uint256 nonce;
    }

    /// @notice EIP-712 domain typehash.
    bytes32 public constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    /// @notice EIP-712 NeuralAdvisement struct typehash.
    bytes32 public constant NEURAL_ADVISEMENT_TYPEHASH = keccak256(
        "NeuralAdvisement(bytes32 marketId,uint8 regime,uint16 riskScoreBps,uint16 recommendedHedgeBps,uint64 issuedAt,uint64 validUntil,uint256 nonce)"
    );

    /// @notice Secp256k1 half-order upper bound for EIP-2 signature malleability protection.
    uint256 private constant SECP256K1_N_DIV_2 =
        0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;

    uint256 private constant DEFAULT_BASE_PRICE_E8 = 32e10; // $3,200.00 scaled by 1e8
    uint256 private constant DEFAULT_INITIAL_VOL_BPS = 120;
    uint256 private constant SIGNATURE_LENGTH = 65;
    uint8 private constant SIG_V_LOWER = 27;
    uint8 private constant SIG_V_UPPER = 28;

    /// @notice Contract administrator.
    address public owner;

    /// @notice Pending owner for two-step ownership transfer.
    address public pendingOwner;

    /// @notice Authorized EIP-712 signer for the live Neural Risk Sentinel.
    address public neuralSigner;

    /// @notice Monotonic epoch incremented on every neural signer rotation.
    uint256 public neuralSignerEpoch;

    /// @notice Whether open demo triggers are enabled for testnet demonstrations.
    bool public demoModeEnabled;

    /// @notice Addresses authorized to post market ticks and health factor alerts.
    mapping(address => bool) public authorizedReporters;

    /// @notice Latest market snapshot per marketId.
    mapping(bytes32 => MarketState) public markets;

    /// @notice Latest verified neural snapshot per marketId.
    mapping(bytes32 => OmniGuardTypes.NeuralSnapshot) public latestNeuralState;

    /// @notice Monotonically increasing EIP-712 nonce per marketId for replay protection.
    mapping(bytes32 => uint256) public neuralNonces;

    /// @notice Emitted on every market price update (opCode = 2: topic0 + indexed marketId).
    event PriceUpdated(
        bytes32 indexed marketId,
        uint256 priceE8,
        uint256 prevPriceE8,
        int256 changeBps,
        uint256 volatilityBps,
        uint64 timestamp
    );

    /// @notice Emitted when a monitored vault's health factor is updated or breached (opCode = 3).
    event HealthFactorAlert(
        address indexed vault,
        address indexed owner,
        uint256 healthFactorBps,
        uint256 collateralUsdE8,
        uint256 debtUsdE8,
        uint64 timestamp
    );

    /// @notice Emitted when a verified EIP-712 Neural Risk Advisement is committed on-chain (opCode = 3).
    event NeuralRegimeCommitted(
        bytes32 indexed marketId,
        address indexed signer,
        uint8 regime,
        uint16 riskScoreBps,
        uint16 recommendedHedgeBps,
        uint64 emittedAt,
        uint64 validUntil
    );

    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event ReporterUpdated(address indexed reporter, bool allowed);
    event NeuralSignerUpdated(address indexed oldSigner, address indexed newSigner, uint256 epoch);
    event NeuralStateCleared(bytes32 indexed marketId);
    event DemoModeUpdated(bool enabled);

    error NotOwner();
    error NotPendingOwner();
    error NotAuthorizedReporter();
    error InvalidAddress();
    error InvalidPrice();
    error InvalidBps(uint256 value);
    error InvalidRegime(uint8 regime);
    error ExpiredAdvisement(uint64 validUntil, uint64 currentTimestamp);
    error AdvisementTtlTooLong(uint64 validUntil, uint64 maxValidUntil);
    error InvalidIssuedAt(uint64 issuedAt, uint64 currentTimestamp);
    error InvalidNonce(uint256 expected, uint256 provided);
    error InvalidSignatureLength(uint256 length);
    error InvalidSignatureValue();
    error UnauthorizedNeuralSigner(address recovered, address expected);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyReporterOrDemo() {
        if (!demoModeEnabled && msg.sender != owner && !authorizedReporters[msg.sender]) {
            revert NotAuthorizedReporter();
        }
        _;
    }

    /**
     * @param owner_ Administrator address.
     * @param neuralSigner_ Authorized EIP-712 signer for the live Neural Risk Sentinel.
     * @param initialWethPriceE8_ Initial WETH/USDC price scaled to 1e8 (e.g., 3200e8 = $3,200.00).
     */
    constructor(address owner_, address neuralSigner_, uint256 initialWethPriceE8_) {
        if (owner_ == address(0) || neuralSigner_ == address(0)) revert InvalidAddress();
        if (initialWethPriceE8_ == 0) revert InvalidPrice();

        owner = owner_;
        neuralSigner = neuralSigner_;
        neuralSignerEpoch = 1;
        authorizedReporters[owner_] = true;
        authorizedReporters[neuralSigner_] = true;

        markets[OmniGuardTypes.MARKET_WETH_USDC] = MarketState({
            lastPriceE8: initialWethPriceE8_,
            lastVolatilityBps: DEFAULT_INITIAL_VOL_BPS,
            lastUpdatedAt: uint64(block.timestamp)
        });
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
        authorizedReporters[owner] = true;
        emit OwnershipTransferred(prev, owner);
    }

    /// @notice Computes the EIP-712 domain separator dynamically for the active chainId.
    function domainSeparator() public view returns (bytes32) {
        return keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes("OmniGuardMarketFeed")),
                keccak256(bytes("1")),
                block.chainid,
                address(this)
            )
        );
    }

    /// @notice Computes the EIP-712 signing digest for a NeuralAdvisement struct.
    function hashNeuralAdvisement(NeuralAdvisement calldata advisement_) public view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                NEURAL_ADVISEMENT_TYPEHASH,
                advisement_.marketId,
                advisement_.regime,
                advisement_.riskScoreBps,
                advisement_.recommendedHedgeBps,
                advisement_.issuedAt,
                advisement_.validUntil,
                advisement_.nonce
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator(), structHash));
    }

    function setReporter(address reporter_, bool allowed_) external onlyOwner {
        if (reporter_ == address(0)) revert InvalidAddress();
        authorizedReporters[reporter_] = allowed_;
        emit ReporterUpdated(reporter_, allowed_);
    }

    /// @notice Rotates the neural EIP-712 signer, revokes the old signer's reporter role (if distinct from owner),
    ///         and increments neuralSignerEpoch so previously cached snapshots from the old key are invalidated.
    function setNeuralSigner(address newSigner_) external onlyOwner {
        if (newSigner_ == address(0)) revert InvalidAddress();
        address prev = neuralSigner;
        if (prev != owner) {
            authorizedReporters[prev] = false;
        }
        neuralSigner = newSigner_;
        authorizedReporters[newSigner_] = true;
        uint256 nextEpoch = ++neuralSignerEpoch;
        emit NeuralSignerUpdated(prev, newSigner_, nextEpoch);
    }

    /// @notice Explicitly clears cached neural state for a market.
    function clearNeuralState(bytes32 marketId_) external onlyOwner {
        delete latestNeuralState[marketId_];
        emit NeuralStateCleared(marketId_);
    }

    /// @notice Returns the active neural snapshot only if signed by the current neuralSigner and unexpired.
    function getActiveNeuralState(bytes32 marketId_) external view returns (OmniGuardTypes.NeuralSnapshot memory snap) {
        snap = latestNeuralState[marketId_];
        if (snap.signer != neuralSigner || snap.validUntil < uint64(block.timestamp)) {
            delete snap;
        }
    }

    function setDemoMode(bool enabled_) external onlyOwner {
        demoModeEnabled = enabled_;
        emit DemoModeUpdated(enabled_);
    }

    /**
     * @notice Posts a live price tick for a market and emits PriceUpdated for Reactive Omni.
     * @param marketId_ Canonical market identifier (e.g., keccak256("WETH/USDC")).
     * @param newPriceE8_ New price scaled by 1e8.
     * @param volatilityBps_ Annualized/realized short-window volatility in bps.
     */
    function postPriceTick(bytes32 marketId_, uint256 newPriceE8_, uint256 volatilityBps_)
        external
        onlyReporterOrDemo
    {
        if (newPriceE8_ == 0) revert InvalidPrice();
        _recordAndEmitPrice(marketId_, newPriceE8_, volatilityBps_);
    }

    /**
     * @notice Simulates a rapid flash-crash price drop in basis points for live testnet demos & latency benchmarks.
     * @param marketId_ Market identifier.
     * @param dropBps_ Basis points drop (e.g., 550 = -5.50%).
     * @param spikeVolatilityBps_ Realized volatility spike in bps.
     */
    function simulateFlashCrash(bytes32 marketId_, uint16 dropBps_, uint256 spikeVolatilityBps_)
        external
        onlyReporterOrDemo
        returns (uint256 newPriceE8)
    {
        if (dropBps_ == 0 || dropBps_ >= OmniGuardTypes.BPS_DENOMINATOR) {
            revert InvalidBps(dropBps_);
        }
        MarketState memory state = markets[marketId_];
        uint256 basePrice = state.lastPriceE8 == 0 ? DEFAULT_BASE_PRICE_E8 : state.lastPriceE8;
        newPriceE8 = (basePrice * (OmniGuardTypes.BPS_DENOMINATOR - dropBps_)) / OmniGuardTypes.BPS_DENOMINATOR;
        if (newPriceE8 == 0) newPriceE8 = 1;
        _recordAndEmitPrice(marketId_, newPriceE8, spikeVolatilityBps_);
    }

    /**
     * @notice Emits a vault health factor telemetry event monitored by Reactive Omni.
     * @param vault_ Monitored vault address.
     * @param positionOwner_ Owner of the position.
     * @param healthFactorBps_ Current health factor in bps (e.g., 11800 = 1.18x).
     * @param collateralUsdE8_ Collateral value in USD (1e8).
     * @param debtUsdE8_ Debt value in USD (1e8).
     */
    function reportHealthFactor(
        address vault_,
        address positionOwner_,
        uint256 healthFactorBps_,
        uint256 collateralUsdE8_,
        uint256 debtUsdE8_
    ) external onlyReporterOrDemo {
        if (vault_ == address(0) || positionOwner_ == address(0)) revert InvalidAddress();
        emit HealthFactorAlert(
            vault_,
            positionOwner_,
            healthFactorBps_,
            collateralUsdE8_,
            debtUsdE8_,
            uint64(block.timestamp)
        );
    }

    /**
     * @notice Verifies an EIP-712 signed Neural Risk Advisement from the running AI Sentinel
     *         and emits NeuralRegimeCommitted so Reactive Omni adapts thresholds and/or dispatches protection.
     * @dev Strictly enforces Unix timestamp expiry, max TTL <= 180s, and issuedAt skew <= 120s.
     */
    function submitSignedNeuralRegime(NeuralAdvisement calldata advisement_, bytes calldata signature_) external {
        if (advisement_.regime > uint8(OmniGuardTypes.RiskRegime.CASCADE_CRITICAL)) {
            revert InvalidRegime(advisement_.regime);
        }
        if (advisement_.riskScoreBps > OmniGuardTypes.BPS_DENOMINATOR) {
            revert InvalidBps(advisement_.riskScoreBps);
        }
        if (advisement_.recommendedHedgeBps > OmniGuardTypes.BPS_DENOMINATOR) {
            revert InvalidBps(advisement_.recommendedHedgeBps);
        }

        uint64 nowTs = uint64(block.timestamp);
        if (advisement_.validUntil < nowTs) {
            revert ExpiredAdvisement(advisement_.validUntil, nowTs);
        }
        uint64 maxValidUntil = nowTs + OmniGuardTypes.MAX_ADVISEMENT_TTL_SECONDS;
        if (advisement_.validUntil > maxValidUntil) {
            revert AdvisementTtlTooLong(advisement_.validUntil, maxValidUntil);
        }
        if (
            advisement_.issuedAt > nowTs + OmniGuardTypes.MAX_ISSUED_AT_SKEW_SECONDS
                || advisement_.issuedAt + OmniGuardTypes.MAX_ISSUED_AT_SKEW_SECONDS < nowTs
        ) {
            revert InvalidIssuedAt(advisement_.issuedAt, nowTs);
        }
        if (advisement_.validUntil < advisement_.issuedAt) {
            revert ExpiredAdvisement(advisement_.validUntil, advisement_.issuedAt);
        }

        uint256 expectedNonce = neuralNonces[advisement_.marketId];
        if (advisement_.nonce != expectedNonce) {
            revert InvalidNonce(expectedNonce, advisement_.nonce);
        }

        bytes32 digest = hashNeuralAdvisement(advisement_);
        address recovered = _recoverSigner(digest, signature_);
        if (recovered != neuralSigner) {
            revert UnauthorizedNeuralSigner(recovered, neuralSigner);
        }

        neuralNonces[advisement_.marketId] = expectedNonce + 1;

        latestNeuralState[advisement_.marketId] = OmniGuardTypes.NeuralSnapshot({
            regime: OmniGuardTypes.RiskRegime(advisement_.regime),
            riskScoreBps: advisement_.riskScoreBps,
            recommendedHedgeBps: advisement_.recommendedHedgeBps,
            emittedAt: nowTs,
            validUntil: advisement_.validUntil,
            signer: recovered
        });

        emit NeuralRegimeCommitted(
            advisement_.marketId,
            recovered,
            advisement_.regime,
            advisement_.riskScoreBps,
            advisement_.recommendedHedgeBps,
            nowTs,
            advisement_.validUntil
        );
    }

    function _recordAndEmitPrice(bytes32 marketId_, uint256 newPriceE8_, uint256 volatilityBps_) internal {
        MarketState storage state = markets[marketId_];
        uint256 prevPriceE8 = state.lastPriceE8;
        int256 changeBps = 0;

        if (prevPriceE8 > 0) {
            int256 diff = int256(newPriceE8_) - int256(prevPriceE8);
            changeBps = (diff * int256(uint256(OmniGuardTypes.BPS_DENOMINATOR))) / int256(prevPriceE8);
        }

        uint64 nowTs = uint64(block.timestamp);
        state.lastPriceE8 = newPriceE8_;
        state.lastVolatilityBps = volatilityBps_;
        state.lastUpdatedAt = nowTs;

        emit PriceUpdated(marketId_, newPriceE8_, prevPriceE8, changeBps, volatilityBps_, nowTs);
    }

    function _recoverSigner(bytes32 digest_, bytes calldata signature_) internal pure returns (address signer) {
        if (signature_.length != SIGNATURE_LENGTH) revert InvalidSignatureLength(signature_.length);

        bytes32 r = bytes32(signature_[0:32]);
        bytes32 s = bytes32(signature_[32:64]);
        uint8 v = uint8(signature_[64]);

        if (v < SIG_V_LOWER) v += SIG_V_LOWER;
        if (v != SIG_V_LOWER && v != SIG_V_UPPER) revert InvalidSignatureValue();
        if (uint256(s) > SECP256K1_N_DIV_2) revert InvalidSignatureValue();

        signer = ecrecover(digest_, v, r, s);
        if (signer == address(0)) revert InvalidSignatureValue();
    }
}
