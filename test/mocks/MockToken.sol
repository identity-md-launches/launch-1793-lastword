// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @dev Local test fixture only; never part of the application deployment.
contract MockToken is IERC20Metadata {
    string public constant name = "Test Token";
    string public constant symbol = "TEST";
    uint8 public immutable decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    error InsufficientBalance();
    error InsufficientAllowance();

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public virtual returns (bool) {
        _spendAllowance(from, amount);
        _transfer(from, to, amount);
        return true;
    }

    function _spendAllowance(address from, uint256 amount) internal {
        uint256 approved = allowance[from][msg.sender];
        if (approved < amount) revert InsufficientAllowance();
        allowance[from][msg.sender] = approved - amount;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        if (balanceOf[from] < amount) revert InsufficientBalance();
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}

contract AdversarialToken is MockToken {
    enum Behavior {
        Normal,
        ReturnFalse,
        RevertTransfer,
        NoReturn,
        NoTransfer,
        ShortTransfer,
        ExtraTransfer,
        MalformedReturn,
        DecreaseSink
    }

    Behavior public behavior;
    address public callbackTarget;
    bytes public callbackData;
    bool public propagateCallbackFailure;
    bool public callbackSucceeded;
    bytes public callbackResult;

    error TokenTransferRejected();

    constructor() MockToken(18) {}

    function setBehavior(Behavior behavior_) external {
        behavior = behavior_;
    }

    function setCallback(address target, bytes calldata data, bool propagateFailure) external {
        callbackTarget = target;
        callbackData = data;
        propagateCallbackFailure = propagateFailure;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (behavior == Behavior.RevertTransfer) revert TokenTransferRejected();
        if (callbackTarget != address(0)) {
            (bool success, bytes memory result) = callbackTarget.call(callbackData);
            callbackSucceeded = success;
            callbackResult = result;
            if (!success && propagateCallbackFailure) {
                assembly ("memory-safe") {
                    revert(add(result, 32), mload(result))
                }
            }
        }
        if (behavior == Behavior.NoTransfer) return true;
        if (behavior == Behavior.DecreaseSink) {
            _transfer(to, from, 1);
            return true;
        }
        if (behavior == Behavior.ShortTransfer) {
            _spendAllowance(from, amount);
            _transfer(from, to, amount - 1);
            _transfer(from, address(this), 1);
            return true;
        }
        if (behavior == Behavior.ExtraTransfer) {
            super.transferFrom(from, to, amount);
            _transfer(from, to, 1);
            return true;
        }
        super.transferFrom(from, to, amount);
        if (behavior == Behavior.ReturnFalse) return false;
        if (behavior == Behavior.NoReturn) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        if (behavior == Behavior.MalformedReturn) {
            assembly ("memory-safe") {
                mstore(0, 2)
                return(0, 32)
            }
        }
        return true;
    }
}

contract NoMetadataToken {}

contract RevertingMetadataToken {
    function decimals() external pure returns (uint8) {
        revert("metadata unavailable");
    }
}
