// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { IPayer } from "@reactive/src/interfaces/IPayer.sol";
import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";

/**
 * @title MockOmniCallbackProxy
 * @notice Local Foundry test double of Reactive Omni's destination CallbackProxy
 *         (Base Sepolia 0x476F44... / Unichain Sepolia 0x775c9B...).
 * @dev Faithfully replicates Reactive Omni's 160-bit first-argument sender overwrite,
 *      130,000 gas proxy overhead reservation (`_extraGas=80k + _maxChargeGas=50k`),
 *      and `IPayer.pay()` settlement accounting.
 */
contract MockOmniCallbackProxy is IPayable {
    uint256 public constant PROXY_OVERHEAD_GAS = 130_000;

    mapping(address => uint256) public reserves;
    mapping(address => uint256) public debts;

    event CallbackFailure(address indexed target_, bytes payload_);

    error NotAContract(address target_);
    error InDebt(address target_, uint256 debtAmount_);
    error InsufficientGas(uint64 requested_, uint256 requiredOverhead_);
    error PayloadTooShort(uint256 length_);

    receive() external payable override {
        depositTo(msg.sender);
    }

    function depositTo(address target_) public payable {
        uint256 amount = msg.value;
        uint256 owed = debts[target_];
        if (owed > 0) {
            if (amount >= owed) {
                debts[target_] = 0;
                reserves[target_] += (amount - owed);
            } else {
                debts[target_] = owed - amount;
            }
        } else {
            reserves[target_] += amount;
        }
    }

    function debt(address contract_) external view override returns (uint256) {
        return debts[contract_];
    }

    /**
     * @notice Delivers a Reactive Omni V_1_0 callback after overwriting the first ABI address argument
     *         (bytes 4..36 of payload) with `reactiveSender_`, mirroring Reactive Signer + CallbackProxy.
     */
    function deliverCallback(
        address reactiveSender_,
        ISystemContract.CallbackConfiguration_V_1_0 memory config_,
        uint256 simulatedFee_
    ) external returns (bool success, bytes memory returnData) {
        address target = config_.recipient;
        if (debts[target] > 0) revert InDebt(target, debts[target]);
        if (target.code.length == 0) revert NotAContract(target);
        if (config_.gasLimit <= PROXY_OVERHEAD_GAS) revert InsufficientGas(config_.gasLimit, PROXY_OVERHEAD_GAS);
        if (config_.payload.length < 36) revert PayloadTooShort(config_.payload.length);

        bytes memory patched = bytes.concat(config_.payload);
        // Overwrite first argument word (bytes 4..35) with reactiveSender_ address (right-aligned 160 bits).
        bytes32 encodedSender = bytes32(uint256(uint160(reactiveSender_)));
        assembly {
            mstore(add(add(patched, 32), 4), encodedSender)
        }

        uint256 forwardedGas = uint256(config_.gasLimit) - PROXY_OVERHEAD_GAS;
        (success, returnData) = target.call{ gas: forwardedGas }(patched);
        if (!success) {
            emit CallbackFailure(target, patched);
        }

        if (simulatedFee_ > 0) {
            _charge(target, simulatedFee_);
        }
    }

    function _charge(address target_, uint256 fee_) internal {
        if (reserves[target_] >= fee_) {
            reserves[target_] -= fee_;
            return;
        }
        uint256 shortfall = fee_ - reserves[target_];
        reserves[target_] = 0;
        debts[target_] += shortfall;
        try IPayer(payable(target_)).pay{ gas: 50_000 }(debts[target_]) { } catch { }
    }
}
