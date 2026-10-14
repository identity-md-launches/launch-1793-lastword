// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LastWordBase} from "./LastWordBase.sol";
import {LastWord} from "../src/LastWord.sol";
import {MockToken} from "./mocks/MockToken.sol";

contract LastWordPaidTest is LastWordBase {
    function setUp() public override {
        super.setUp();
        _connect();
    }

    function test_firstPaidPostBurnsFromAuthorDirectlyToSink() public {
        _fundAndApprove(alice, BASE);
        vm.expectEmit(true, false, false, true, address(board));
        emit MessageSet(alice, "First paid", BASE, vm.getBlockTimestamp());
        _post(alice, "First paid", BASE);
        _assertMessage(board.currentMessage(), alice, "First paid", BASE, vm.getBlockTimestamp());
        assertEq(asset.balanceOf(alice), 0);
        assertEq(asset.balanceOf(sink), BASE);
        assertEq(asset.balanceOf(address(board)), 0);
        assertEq(asset.balanceOf(OWNER), 0);
        assertEq(asset.allowance(alice, address(board)), 0);
        assertEq(asset.totalSupply(), BASE, "sink transfer does not change supply");
        assertEq(board.totalBurned(), BASE);
        assertEq(board.minimumBurn(), 1_100 ether);
    }

    function test_paidPostsHaveNoCooldownAndEscalateByTenPercent() public {
        uint256 second = 1_100 ether;
        uint256 third = 1_210 ether;
        _fundAndApprove(alice, BASE + second + third);
        _post(alice, "One", BASE);
        _post(alice, "Two", second);
        _post(alice, "Three", third);
        assertEq(board.minimumBurn(), 1_331 ether);
        assertEq(board.messageCount(), 3);
        assertEq(board.totalBurned(), BASE + second + third);
        assertEq(asset.balanceOf(sink), board.totalBurned());
    }

    function test_overpaymentSetsNextMinimumFromActualBurnRoundedUp() public {
        uint256 amount = 2_000 ether + 1;
        _fundAndApprove(alice, amount);
        _post(alice, "A higher bid", amount);
        assertEq(board.minimumBurn(), 2_200 ether + 2);
        assertEq(board.totalBurned(), amount);
    }

    function test_belowMinimumOrStaleQuoteRevertsWithoutSpending() public {
        _fundAndApprove(alice, BASE);
        _fundAndApprove(bob, BASE);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LastWord.BurnTooSmall.selector, BASE, BASE - 1));
        board.setMessage("Under floor", BASE - 1);
        _post(alice, "Wins ordering", BASE);
        bytes32 beforeState = _snapshot();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(LastWord.BurnTooSmall.selector, 1_100 ether, BASE));
        board.setMessage("Stale quote", BASE);
        assertEq(asset.balanceOf(bob), BASE);
        assertEq(asset.allowance(bob, address(board)), BASE);
        assertEq(_snapshot(), beforeState);
    }

    function test_resetAtExactlyTwentyFourHoursRestoresFloorWithoutClearingMessage() public {
        uint256 start = vm.getBlockTimestamp();
        _fundAndApprove(alice, 3 * BASE);
        _post(alice, "Stands for a day", 2 * BASE);
        vm.warp(start + 24 hours - 1);
        assertEq(board.minimumBurn(), 2_200 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LastWord.BurnTooSmall.selector, 2_200 ether, BASE));
        board.setMessage("Not yet reset", BASE);
        vm.warp(start + 24 hours);
        assertEq(board.minimumBurn(), BASE);
        _assertMessage(board.currentMessage(), alice, "Stands for a day", 2 * BASE, start);
        assertEq(board.totalBurned(), 2 * BASE);
        _post(alice, "Reset floor", BASE);
        assertEq(board.minimumBurn(), 1_100 ether);
        assertEq(board.totalBurned(), 3 * BASE);
    }

    function test_everySuccessfulReplacementRestartsInactivityClock() public {
        _fundAndApprove(alice, BASE + 1_100 ether);
        uint256 start = vm.getBlockTimestamp();
        _post(alice, "First", BASE);
        vm.warp(start + 23 hours);
        _post(alice, "New clock", 1_100 ether);
        vm.warp(start + 24 hours);
        assertEq(board.minimumBurn(), 1_210 ether);
        vm.warp(start + 47 hours);
        assertEq(board.minimumBurn(), BASE);
    }

    function test_approvalMustComeFromAuthorAndOtherApprovalsCannotBeSpent() public {
        _fundAndApprove(bob, BASE);
        asset.mint(alice, BASE);
        bytes32 beforeState = _snapshot();
        vm.prank(alice);
        vm.expectRevert(MockToken.InsufficientAllowance.selector);
        board.setMessage("Cannot spend Bob's approval", BASE);
        assertEq(asset.balanceOf(bob), BASE);
        assertEq(asset.allowance(bob, address(board)), BASE);
        assertEq(_snapshot(), beforeState);
    }

    function test_insufficientBalanceRollsBackAllowanceAndBoard() public {
        asset.mint(alice, BASE - 1);
        vm.prank(alice);
        asset.approve(address(board), BASE);
        bytes32 beforeState = _snapshot();
        vm.prank(alice);
        vm.expectRevert(MockToken.InsufficientBalance.selector);
        board.setMessage("Insufficient balance", BASE);
        assertEq(asset.allowance(alice, address(board)), BASE);
        assertEq(asset.balanceOf(sink), 0);
        assertEq(_snapshot(), beforeState);
    }

    function test_unrelatedSinkTransfersDoNotCountAsPostsOrBurnedTotal() public {
        _fundAndApprove(alice, 2 * BASE);
        vm.prank(alice);
        asset.transfer(sink, BASE);
        assertEq(board.totalBurned(), 0);
        assertEq(board.messageCount(), 0);
        assertEq(board.minimumBurn(), BASE);
        _post(alice, "Only this counts", BASE);
        assertEq(board.totalBurned(), BASE);
        assertEq(asset.balanceOf(sink), 2 * BASE);
    }

    function test_minimumOverflowIsExplicitAndRecoversAfterReset() public {
        uint256 largeBurn = type(uint256).max - BASE;
        _fundAndApprove(alice, type(uint256).max);
        _post(alice, "Huge burn", largeBurn);
        vm.expectRevert(LastWord.MinimumBurnOverflow.selector);
        board.minimumBurn();
        vm.prank(alice);
        vm.expectRevert(LastWord.MinimumBurnOverflow.selector);
        board.setMessage("Must wait", BASE);
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        assertEq(board.minimumBurn(), BASE);
        _post(alice, "After reset", BASE);
        assertEq(board.totalBurned(), type(uint256).max);
        assertEq(asset.balanceOf(sink), type(uint256).max);
    }

    function testFuzz_minimumRoundsUpAndConservesBalances(uint128 amount) public {
        uint256 burn = bound(uint256(amount), BASE, type(uint128).max);
        _fundAndApprove(alice, burn);
        _post(alice, "Fuzzed burn", burn);
        uint256 next = board.minimumBurn();
        assertGe(next * 10, burn * 11);
        assertLt((next - 1) * 10, burn * 11);
        assertEq(board.totalBurned(), burn);
        assertEq(asset.balanceOf(alice) + asset.balanceOf(sink) + asset.balanceOf(address(board)), burn);
    }

    function testFuzz_resetForAnyIdlePeriodAtLeastOneDay(uint32 idleSeconds) public {
        uint256 idle = bound(idleSeconds, 24 hours, type(uint32).max);
        _fundAndApprove(alice, 2 * BASE);
        _post(alice, "Waiting", 2 * BASE);
        vm.warp(vm.getBlockTimestamp() + idle);
        assertEq(board.minimumBurn(), BASE);
        assertEq(board.messageCount(), 1);
        assertEq(board.totalBurned(), 2 * BASE);
    }
}
