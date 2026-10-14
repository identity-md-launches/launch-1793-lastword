// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LastWordBase} from "./LastWordBase.sol";
import {LastWord} from "../src/LastWord.sol";
import {AdversarialToken} from "./mocks/MockToken.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract LastWordAdversarialTest is LastWordBase {
    AdversarialToken internal adversary;

    function setUp() public override {
        super.setUp();
        adversary = new AdversarialToken();
        asset = adversary;
        _connect();
        _fundAndApprove(alice, 1_000_000 ether);
        _post(alice, "Existing message", BASE);
    }

    function test_noReturnTokenIsSupportedWhenSinkReceivesExactAmount() public {
        adversary.setBehavior(AdversarialToken.Behavior.NoReturn);
        _post(alice, "No return value", 1_100 ether);
        assertEq(board.messageCount(), 2);
        assertEq(board.totalBurned(), 2_100 ether);
        assertEq(asset.balanceOf(sink), 2_100 ether);
    }

    function test_falseReturnRollsBackEvenIfTokenAlreadyMovedFunds() public {
        _failedTransfer(
            AdversarialToken.Behavior.ReturnFalse,
            abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(asset))
        );
    }

    function test_revertingTokenRollsBackEntirePost() public {
        _failedTransfer(
            AdversarialToken.Behavior.RevertTransfer,
            abi.encodeWithSelector(AdversarialToken.TokenTransferRejected.selector)
        );
    }

    function test_fakeSuccessWithoutTransferReverts() public {
        _failedTransfer(
            AdversarialToken.Behavior.NoTransfer, abi.encodeWithSelector(LastWord.BurnAmountMismatch.selector)
        );
    }

    function test_feeOnTransferRevertsAndRestoresBalances() public {
        _failedTransfer(
            AdversarialToken.Behavior.ShortTransfer, abi.encodeWithSelector(LastWord.BurnAmountMismatch.selector)
        );
        assertEq(asset.balanceOf(address(asset)), 0);
    }

    function test_extraTransferRevertsAndRestoresBalances() public {
        _failedTransfer(
            AdversarialToken.Behavior.ExtraTransfer, abi.encodeWithSelector(LastWord.BurnAmountMismatch.selector)
        );
    }

    function test_malformedReturnRevertsAndRestoresBalances() public {
        _failedTransfer(
            AdversarialToken.Behavior.MalformedReturn,
            abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(asset))
        );
    }

    function test_decreasingSinkBalanceRevertsWithClearError() public {
        _failedTransfer(
            AdversarialToken.Behavior.DecreaseSink, abi.encodeWithSelector(LastWord.BurnAmountMismatch.selector)
        );
    }

    function test_caughtReentrancyCannotReplaceOuterPost() public {
        adversary.setCallback(
            address(board), abi.encodeCall(board.setMessage, ("Reentrant overwrite", 1_210 ether)), false
        );
        _post(alice, "Outer post", 1_100 ether);
        assertFalse(adversary.callbackSucceeded());
        assertEq(
            adversary.callbackResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
        );
        _assertMessage(board.currentMessage(), alice, "Outer post", 1_100 ether, vm.getBlockTimestamp());
        assertEq(board.messageCount(), 2);
        assertEq(board.totalBurned(), 2_100 ether);
        assertEq(asset.balanceOf(sink), board.totalBurned());
    }

    function test_propagatedReentrancyRevertsOuterPostAtomically() public {
        adversary.setCallback(address(board), abi.encodeCall(board.setMessage, ("Nested", 1_210 ether)), true);
        bytes32 beforeState = _snapshot();
        uint256 beforeBalance = asset.balanceOf(alice);
        uint256 beforeAllowance = asset.allowance(alice, address(board));
        vm.prank(alice);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        board.setMessage("Must revert", 1_100 ether);
        assertEq(_snapshot(), beforeState);
        assertEq(asset.balanceOf(alice), beforeBalance);
        assertEq(asset.allowance(alice, address(board)), beforeAllowance);
        assertEq(asset.balanceOf(sink), BASE);
    }

    function test_reentryIntoTokenConfigurationIsBlocked() public {
        adversary.setCallback(address(board), abi.encodeCall(board.setToken, (address(adversary))), false);
        _post(alice, "Outer post", 1_100 ether);
        assertFalse(adversary.callbackSucceeded());
        assertEq(
            adversary.callbackResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
        );
        assertEq(board.token(), address(adversary));
    }

    function test_failedReplacementDoesNotRestartInactivityClock() public {
        uint256 initialTimestamp = board.currentMessage().timestamp;
        vm.warp(initialTimestamp + 23 hours);
        _failedTransfer(
            AdversarialToken.Behavior.RevertTransfer,
            abi.encodeWithSelector(AdversarialToken.TokenTransferRejected.selector)
        );
        vm.warp(initialTimestamp + 24 hours);
        assertEq(board.minimumBurn(), BASE);
    }

    function test_failedTransferDoesNotOverwriteWrappedHistory() public {
        for (uint256 i = 1; i < 55; ++i) {
            vm.warp(vm.getBlockTimestamp() + 24 hours);
            _post(alice, vm.toString(i), BASE);
        }
        assertEq(board.historyCount(), 50);
        _failedTransfer(
            AdversarialToken.Behavior.ReturnFalse,
            abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(asset))
        );
        assertEq(board.getMessage(0).text, "5");
        assertEq(board.currentMessage().text, "54");
    }

    function _failedTransfer(AdversarialToken.Behavior behavior, bytes memory errorData) internal {
        adversary.setBehavior(behavior);
        bytes32 beforeState = _snapshot();
        uint256 beforeBalance = asset.balanceOf(alice);
        uint256 beforeSink = asset.balanceOf(sink);
        uint256 beforeAllowance = asset.allowance(alice, address(board));
        uint256 amount = board.minimumBurn();
        vm.prank(alice);
        vm.expectRevert(errorData);
        board.setMessage("Must not replace", amount);
        assertEq(_snapshot(), beforeState);
        assertEq(asset.balanceOf(alice), beforeBalance);
        assertEq(asset.balanceOf(sink), beforeSink);
        assertEq(asset.allowance(alice, address(board)), beforeAllowance);
        assertEq(asset.balanceOf(address(board)), 0);
    }
}
