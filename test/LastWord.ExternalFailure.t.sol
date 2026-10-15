// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LastWordBase} from "./LastWordBase.sol";
import {LastWord} from "src/LastWord.sol";
import {MockToken} from "./mocks/MockToken.sol";
import {BalanceReadFailureToken} from "./mocks/BalanceReadFailureToken.sol";

contract LastWordBalanceReadFailureTest is LastWordBase {
    BalanceReadFailureToken private readAsset;

    function setUp() public override {
        super.setUp();
        readAsset = new BalanceReadFailureToken();
    }

    function test_balanceQueryRevertBeforeTransferRestoresPostAndAllowsRetry() public {
        _configureAndFund();
        _rejectAndRecover(BalanceReadFailureToken.Fault.RevertBeforeTransfer);
    }

    function test_balanceQueryRevertAfterTransferRestoresFundsAndAllowsRetry() public {
        _configureAndFund();
        _rejectAndRecover(BalanceReadFailureToken.Fault.RevertAfterTransfer);
    }

    function test_emptyBalanceReturnAfterTransferRestoresFundsAndAllowsRetry() public {
        _configureAndFund();
        _rejectAndRecover(BalanceReadFailureToken.Fault.EmptyAfterTransfer);
    }

    function test_shortBalanceReturnAfterTransferRestoresFundsAndAllowsRetry() public {
        _configureAndFund();
        _rejectAndRecover(BalanceReadFailureToken.Fault.ShortAfterTransfer);
    }

    function test_lateBalanceReadFailureRestoresOverwrittenLongStringInFullHistory() public {
        string memory longText = _repeat(hex"f09f9880", 140);
        _post(alice, longText, 0);
        for (uint256 i = 1; i < 50; ++i) {
            vm.warp(vm.getBlockTimestamp() + 600);
            _post(alice, vm.toString(i), 0);
        }
        _configureAndFund();
        // This failure occurs after LastWord has replaced slot zero's 560-byte string
        // and after the token has spent the allowance and moved the author's funds.
        _rejectAndRecover(BalanceReadFailureToken.Fault.RevertAfterTransfer);
        assertEq(board.getMessage(0).text, "1");
        assertEq(board.historyCount(), 50);
        assertEq(board.messageCount(), 51);
    }

    function _configureAndFund() private {
        vm.prank(OWNER);
        board.setToken(address(readAsset));
        readAsset.mint(alice, 3 * BASE);
        vm.prank(alice);
        readAsset.approve(address(board), 3 * BASE);
    }

    function _rejectAndRecover(BalanceReadFailureToken.Fault fault) private {
        uint256 amount = board.minimumBurn();
        bytes32 beforeBoard = _snapshot();
        uint256 count = board.messageCount();
        readAsset.setFault(fault);
        vm.prank(alice);
        if (
            fault == BalanceReadFailureToken.Fault.RevertBeforeTransfer
                || fault == BalanceReadFailureToken.Fault.RevertAfterTransfer
        ) {
            vm.expectRevert(BalanceReadFailureToken.BalanceReadRejected.selector);
        } else {
            // Solidity rejects short ABI returndata with an empty revert payload.
            vm.expectRevert(bytes(""));
        }
        board.setMessage("x", amount);
        assertEq(_snapshot(), beforeBoard, "all public board state must roll back");
        assertEq(readAsset.rawBalanceOf(alice), 3 * BASE);
        assertEq(readAsset.rawBalanceOf(sink), 0);
        assertEq(readAsset.rawBalanceOf(address(board)), 0);
        assertEq(readAsset.allowance(alice, address(board)), 3 * BASE);
        assertEq(readAsset.totalSupply(), 3 * BASE);
        assertFalse(readAsset.transferred(), "token-side writes must also roll back");

        readAsset.setFault(BalanceReadFailureToken.Fault.None);
        vm.expectEmit(true, false, false, true, address(board));
        emit MessageSet(alice, "x", amount, vm.getBlockTimestamp());
        _post(alice, "x", amount);
        assertEq(board.messageCount(), count + 1);
        assertEq(board.totalBurned(), amount);
        assertEq(readAsset.rawBalanceOf(sink), amount);
        assertEq(readAsset.rawBalanceOf(alice), 3 * BASE - amount);
        assertEq(readAsset.allowance(alice, address(board)), 3 * BASE - amount);
    }
}

contract LastWordMetadataDecodeTest is LastWordBase {
    function test_shortOrNonCanonicalMetadataLeavesSlotAndHistoryUntouched() public {
        _post(alice, "Before metadata rejection", 0);
        bytes32 beforeState = _snapshot();
        bytes[] memory malformed = new bytes[](5);
        malformed[0] = "";
        malformed[1] = hex"12";
        malformed[2] = new bytes(31);
        malformed[3] = abi.encode(uint256(256));
        malformed[4] = abi.encode(type(uint256).max);
        for (uint256 i; i < malformed.length; ++i) {
            vm.mockCall(address(asset), abi.encodeWithSignature("decimals()"), malformed[i]);
            vm.prank(OWNER);
            // ABI decode failures may happen outside the try/catch; rejection and rollback
            // are the requirement, rather than a particular diagnostic selector.
            vm.expectRevert();
            board.setToken(address(asset));
            assertEq(board.token(), address(0));
            assertEq(board.tokenDecimals(), 0);
            assertEq(board.baseMinimumBurn(), 0);
            assertEq(_snapshot(), beforeState);
            vm.clearMockedCalls();
        }
        _connect();
        assertEq(board.token(), address(asset));
        assertEq(board.minimumBurn(), BASE);
        assertEq(board.currentMessage().text, "Before metadata rejection");
    }
}

/// @dev Both posts occur within one external call, as a contract wallet can batch on chain.
contract LastWordPostingWallet {
    function postTwice(LastWord board, MockToken asset, uint256 first, uint256 second)
        external
        returns (bool secondSuccess, bytes memory secondResult)
    {
        asset.approve(address(board), first + second);
        board.setMessage("Wallet first", first);
        return address(board).call(abi.encodeCall(board.setMessage, ("Wallet second", second)));
    }
}

contract LastWordContractWalletTest is LastWordBase {
    function test_batchedFreePostsEnforceCooldownAndAttributeToWallet() public {
        LastWordPostingWallet wallet = new LastWordPostingWallet();
        vm.prank(alice, alice);
        (bool secondSuccess, bytes memory result) = wallet.postTwice(board, asset, 0, 0);
        assertFalse(secondSuccess);
        assertEq(result, abi.encodeWithSelector(LastWord.CooldownActive.selector, vm.getBlockTimestamp() + 600));
        _assertMessage(board.currentMessage(), address(wallet), "Wallet first", 0, vm.getBlockTimestamp());
        assertEq(board.messageCount(), 1);
        assertEq(board.nextFreePostAt(alice), 0);
        // The EOA and a second wallet have independent cooldowns even with the same origin.
        _post(alice, "EOA post", 0);
        LastWordPostingWallet secondWallet = new LastWordPostingWallet();
        vm.prank(alice, alice);
        (secondSuccess,) = secondWallet.postTwice(board, asset, 0, 0);
        assertFalse(secondSuccess);
        assertEq(board.messageCount(), 3);
        assertEq(board.currentMessage().author, address(secondWallet));
    }

    function test_batchedPaidPostsSpendWalletApprovalAndEscalateWithinOneTransaction() public {
        _connect();
        LastWordPostingWallet wallet = new LastWordPostingWallet();
        uint256 second = 1_100 ether;
        asset.mint(address(wallet), BASE + second);
        // Approval belonging to the transaction origin must remain untouched.
        _fundAndApprove(alice, 10 * BASE);
        vm.prank(alice, alice);
        (bool secondSuccess,) = wallet.postTwice(board, asset, BASE, second);
        assertTrue(secondSuccess);
        assertEq(board.messageCount(), 2);
        _assertMessage(board.getMessage(0), address(wallet), "Wallet first", BASE, vm.getBlockTimestamp());
        _assertMessage(board.getMessage(1), address(wallet), "Wallet second", second, vm.getBlockTimestamp());
        assertEq(board.minimumBurn(), 1_210 ether);
        assertEq(board.totalBurned(), BASE + second);
        assertEq(asset.balanceOf(sink), BASE + second);
        assertEq(asset.balanceOf(address(wallet)), 0);
        assertEq(asset.allowance(address(wallet), address(board)), 0);
        assertEq(asset.balanceOf(alice), 10 * BASE);
        assertEq(asset.allowance(alice, address(board)), 10 * BASE);
    }

    function test_caughtStaleSecondBidPreservesFirstPostAndUnspentWalletAllowance() public {
        _connect();
        LastWordPostingWallet wallet = new LastWordPostingWallet();
        asset.mint(address(wallet), 2 * BASE);
        (bool secondSuccess, bytes memory result) = wallet.postTwice(board, asset, BASE, BASE);
        assertFalse(secondSuccess);
        assertEq(result, abi.encodeWithSelector(LastWord.BurnTooSmall.selector, 1_100 ether, BASE));
        _assertMessage(board.currentMessage(), address(wallet), "Wallet first", BASE, vm.getBlockTimestamp());
        assertEq(board.messageCount(), 1);
        assertEq(board.totalBurned(), BASE);
        assertEq(asset.balanceOf(address(wallet)), BASE);
        assertEq(asset.allowance(address(wallet), address(board)), BASE);
        assertEq(asset.balanceOf(sink), BASE);
    }
}
