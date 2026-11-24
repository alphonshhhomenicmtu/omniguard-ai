// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { IPayer } from "@reactive/src/interfaces/IPayer.sol";

/**
 * @title MockOmniSystem
 * @notice Local Foundry test double of Reactive Omni's SystemContract (0x8888...8888).
 *         Mirrors subscription events, `requestCallbackV_1_0`, `CallbackRequest` recording,
 *         reserves/debt accounting, and `trigger()` execution semantics.
 */
contract MockOmniSystem is ISystemContract {
    struct Subscription {
        address subscriber;
        uint256 chainId;
        address contractAddress;
        uint256 topic0;
        uint256 topic1;
        uint256 topic2;
        uint256 topic3;
        bool active;
    }

    struct RecordedCallback {
        address sender;
        CallbackConfiguration_V_1_0 config;
    }

    Subscription[] public subscriptions;
    RecordedCallback[] public callbackQueue;
    mapping(address => uint256) public reserves;
    mapping(address => uint256) public debts;

    event Subscribe(
        address indexed subscriber,
        uint256 indexed chainId,
        address indexed contractAddress,
        uint256 topic0,
        uint256 topic1,
        uint256 topic2,
        uint256 topic3
    );

    event Unsubscribe(
        address indexed subscriber,
        uint256 indexed chainId,
        address indexed contractAddress,
        uint256 topic0,
        uint256 topic1,
        uint256 topic2,
        uint256 topic3
    );

    event CallbackRequest(
        uint256 indexed chainId_,
        address indexed sender_,
        address indexed recipient_,
        CallbackVersion version_,
        bytes configuration_
    );

    event ReactiveContractReverted(address indexed reactive_, IReactive.LogRecord log_, bytes error_);

    error InDebt(address target, uint256 debtAmount);
    error InvalidCallbackVersion(CallbackVersion version);

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

    function subscribe(
        uint256 chainId_,
        address contract_,
        uint256 topic0_,
        uint256 topic1_,
        uint256 topic2_,
        uint256 topic3_
    ) external override {
        subscriptions.push(
            Subscription({
                subscriber: msg.sender,
                chainId: chainId_,
                contractAddress: contract_,
                topic0: topic0_,
                topic1: topic1_,
                topic2: topic2_,
                topic3: topic3_,
                active: true
            })
        );
        emit Subscribe(msg.sender, chainId_, contract_, topic0_, topic1_, topic2_, topic3_);
    }

    function unsubscribe(
        uint256 chainId_,
        address contract_,
        uint256 topic0_,
        uint256 topic1_,
        uint256 topic2_,
        uint256 topic3_
    ) external override {
        for (uint256 i = 0; i < subscriptions.length; ++i) {
            Subscription storage s = subscriptions[i];
            if (
                s.active && s.subscriber == msg.sender && s.chainId == chainId_ && s.contractAddress == contract_
                    && s.topic0 == topic0_ && s.topic1 == topic1_ && s.topic2 == topic2_ && s.topic3 == topic3_
            ) {
                s.active = false;
            }
        }
        emit Unsubscribe(msg.sender, chainId_, contract_, topic0_, topic1_, topic2_, topic3_);
    }

    function requestCallback(CallbackVersion version_, bytes memory config_) external override {
        if (version_ != CallbackVersion.V_1_0) revert InvalidCallbackVersion(version_);
        CallbackConfiguration_V_1_0 memory cfg = abi.decode(config_, (CallbackConfiguration_V_1_0));
        callbackQueue.push(RecordedCallback({ sender: msg.sender, config: cfg }));
        emit CallbackRequest(cfg.chainId, msg.sender, cfg.recipient, version_, config_);
    }

    function requestCallbackV_1_0(CallbackConfiguration_V_1_0 memory config_) external override {
        bytes memory encoded = abi.encode(config_);
        callbackQueue.push(RecordedCallback({ sender: msg.sender, config: config_ }));
        emit CallbackRequest(config_.chainId, msg.sender, config_.recipient, CallbackVersion.V_1_0, encoded);
    }

    function trigger(IReactive target_, IReactive.LogRecord calldata log_, uint256 simulatedFee_)
        external
        returns (bool succeeded)
    {
        if (debts[address(target_)] > 0) revert InDebt(address(target_), debts[address(target_)]);

        try target_.react(log_) {
            succeeded = true;
        } catch (bytes memory err) {
            emit ReactiveContractReverted(address(target_), log_, err);
            succeeded = false;
        }

        if (simulatedFee_ > 0) {
            _charge(address(target_), simulatedFee_);
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

    function subscriptionCount() external view returns (uint256) {
        return subscriptions.length;
    }

    function callbackCount() external view returns (uint256) {
        return callbackQueue.length;
    }

    function getCallback(uint256 index_) external view returns (RecordedCallback memory) {
        return callbackQueue[index_];
    }

    function clearCallbacks() external {
        delete callbackQueue;
    }
}
