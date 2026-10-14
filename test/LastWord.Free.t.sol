// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LastWordBase} from "./LastWordBase.sol";
import {LastWord} from "../src/LastWord.sol";

contract LastWordFreeTest is LastWordBase {
    function test_firstPostIsFreeAndEmitsExactEvent() public {
        uint256 timestamp = vm.getBlockTimestamp();
        vm.expectEmit(true, false, false, true, address(board));
        emit MessageSet(alice, "Hello, world", 0, timestamp);
        _post(alice, "Hello, world", 0);
        _assertMessage(board.currentMessage(), alice, "Hello, world", 0, timestamp);
        assertEq(board.totalBurned(), 0);
        assertEq(board.nextFreePostAt(alice), timestamp + 10 minutes);
        assertEq(board.messageCount(), 1);
    }

    function test_cooldownIsPerWalletAndExactBoundaryIsAllowed() public {
        uint256 timestamp = vm.getBlockTimestamp();
        _post(alice, "First", 0);
        _post(bob, "Second wallet", 0);
        bytes32 beforeState = _snapshot();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LastWord.CooldownActive.selector, timestamp + 10 minutes));
        board.setMessage("Too soon", 0);
        assertEq(_snapshot(), beforeState);

        vm.warp(timestamp + 10 minutes - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LastWord.CooldownActive.selector, timestamp + 10 minutes));
        board.setMessage("Still too soon", 0);
        vm.warp(timestamp + 10 minutes);
        _post(alice, "At boundary", 0);
        _assertMessage(board.currentMessage(), alice, "At boundary", 0, timestamp + 10 minutes);
        assertEq(board.messageCount(), 3);
    }

    function test_firstPostAtTimestampZeroAndImmediateRepeatRejected() public {
        vm.warp(0);
        _post(alice, "At genesis time", 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LastWord.CooldownActive.selector, 600));
        board.setMessage("No bypass", 0);
        vm.warp(600);
        _post(alice, "Cooldown elapsed", 0);
        assertEq(board.messageCount(), 2);
    }

    function test_identicalTextCanBePostedSubjectToNormalRules() public {
        _post(alice, "Same", 0);
        _post(bob, "Same", 0);
        assertEq(board.currentMessage().author, bob);
        assertEq(board.messageCount(), 2);
    }

    function test_ownerHasSameCooldownAsEveryoneElse() public {
        _post(OWNER, "Creator post", 0);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(LastWord.CooldownActive.selector, vm.getBlockTimestamp() + 10 minutes));
        board.setMessage("No privilege", 0);
    }

    function test_freeModeRejectsBurnAmountAndDoesNotConsumeCooldown() public {
        vm.prank(alice);
        vm.expectRevert(LastWord.FreePostRequiresZeroBurn.selector);
        board.setMessage("Unexpected token amount", 1);
        assertEq(board.nextFreePostAt(alice), 0);
        assertEq(board.messageCount(), 0);
        _post(alice, "Retry", 0);
    }

    function test_tokenConnectionImmediatelySwitchesToPaidAndKeepsHistory() public {
        uint256 timestamp = vm.getBlockTimestamp();
        _post(alice, "Before the token", 0);
        _connect();
        assertEq(board.minimumBurn(), BASE);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(LastWord.BurnTooSmall.selector, BASE, 0));
        board.setMessage("Free mode ended", 0);
        _fundAndApprove(alice, BASE);
        _post(alice, "Paid immediately", BASE);
        _assertMessage(board.getMessage(0), alice, "Before the token", 0, timestamp);
        _assertMessage(board.getMessage(1), alice, "Paid immediately", BASE, timestamp);
        assertEq(board.messageCount(), 2);
        assertEq(board.nextFreePostAt(alice), timestamp + 10 minutes);
    }

    function testFuzz_cooldownCannotBeBypassed(uint16 secondsPassed) public {
        secondsPassed = uint16(bound(secondsPassed, 0, 599));
        uint256 availableAt = vm.getBlockTimestamp() + 600;
        _post(alice, "First", 0);
        vm.warp(vm.getBlockTimestamp() + secondsPassed);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LastWord.CooldownActive.selector, availableAt));
        board.setMessage("Early", 0);
        assertEq(board.messageCount(), 1);
    }
}
