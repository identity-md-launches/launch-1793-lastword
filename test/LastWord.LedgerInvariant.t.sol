// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LastWord} from "src/LastWord.sol";
import {MockToken} from "./mocks/MockToken.sol";

/// @dev A fixed-supply model, with no minting or balance repair during the campaign.
///      Expected balances, allowances, messages and prices come from inputs, not board getters.
contract LastWordLedgerHandler is Test {
    address public constant OWNER = address(bytes20(hex"b77161bbaf98470c6c5101899d30df413f9a019d"));
    address public constant SINK = 0x000000000000000000000000000000000000dEaD;
    uint256 public constant ENDOWMENT = 1e30;
    uint256 public constant BASE = 1_000 * 1e6;

    LastWord public immutable board;
    MockToken public immutable asset;
    address[4] public actors;
    mapping(address => uint256) public expectedBalance;
    mapping(address => uint256) public expectedAllowance;
    mapping(address => uint256) public expectedCooldown;
    LastWord.Message[] private _messages;
    uint256 public burned;
    uint256 public donatedToSink;
    uint256 public donatedToBoard;
    uint256 public successfulPaidPosts;
    uint256 public rejectedPosts;

    event MessageSet(address indexed author, string text, uint256 burned, uint256 timestamp);

    constructor(LastWord board_, MockToken asset_) {
        board = board_;
        asset = asset_;
        actors[0] = makeAddr("ledger-alice");
        actors[1] = makeAddr("ledger-bob");
        actors[2] = makeAddr("ledger-carol");
        actors[3] = OWNER;
        for (uint256 i; i < actors.length; ++i) {
            asset.mint(actors[i], ENDOWMENT);
            expectedBalance[actors[i]] = ENDOWMENT;
            _approve(actors[i], type(uint256).max);
        }

        // Put the buffer one post before wrapping, with free history that must survive connection.
        for (uint256 i; i < 50; ++i) {
            vm.warp(vm.getBlockTimestamp() + 600);
            address author = actors[i % actors.length];
            string memory text = _text(i);
            vm.prank(author);
            board.setMessage(text, 0);
            _messages.push(LastWord.Message(author, text, 0, vm.getBlockTimestamp()));
            expectedCooldown[author] = vm.getBlockTimestamp() + 600;
        }
        vm.prank(OWNER);
        board.setToken(address(asset));
    }

    function approve(uint8 who, uint256 raw, uint8 mode) public {
        uint256 minimum = expectedMinimum();
        uint256 amount;
        mode %= 5;
        if (mode == 1) amount = minimum - 1;
        else if (mode == 2) amount = minimum;
        else if (mode == 3) amount = type(uint256).max;
        else if (mode == 4) amount = bound(raw, 0, ENDOWMENT);
        _approve(actors[who % 4], amount);
    }

    function post(uint8 who, uint96 extra, uint8 textKind) public {
        address author = actors[who % 4];
        uint256 amount = expectedMinimum() + bound(extra, 0, 10 * BASE);
        _attempt(author, _text(textKind), amount, _paymentError(author, amount));
    }

    function approveAndPost(uint8 who, uint96 extra, uint8 textKind) public {
        address author = actors[who % 4];
        uint256 amount = expectedMinimum() + bound(extra, 0, 10 * BASE);
        _approve(author, amount);
        _attempt(author, _text(textKind), amount, _paymentError(author, amount));
    }

    function rejectPost(uint8 who, uint256 raw, uint8 reason) public {
        address author = actors[who % 4];
        uint256 minimum = expectedMinimum();
        reason %= 4;
        if (reason == 0) {
            uint256 amount = bound(raw, 0, minimum - 1);
            _attempt(
                author, "underpaid", amount, abi.encodeWithSelector(LastWord.BurnTooSmall.selector, minimum, amount)
            );
        } else if (reason == 1) {
            _attempt(author, "", minimum, abi.encodeWithSelector(LastWord.InvalidMessageLength.selector));
        } else if (reason == 2) {
            bytes memory invalid = hex"616263eda080";
            _attempt(author, string(invalid), minimum, abi.encodeWithSelector(LastWord.InvalidUtf8.selector));
        } else {
            _attempt(author, _repeat("z", 141), minimum, abi.encodeWithSelector(LastWord.InvalidMessageLength.selector));
        }
    }

    /// @dev Destinations include peers, the prescribed sink, and unsolicited board deposits.
    function transfer(uint8 who, uint8 destination, uint256 raw) public {
        address from = actors[who % 4];
        destination %= 6;
        address to = destination < 4 ? actors[destination] : destination == 4 ? SINK : address(board);
        uint256 amount = bound(raw, 0, expectedBalance[from]);
        vm.prank(from);
        asset.transfer(to, amount);
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount;
        if (to == SINK) donatedToSink += amount;
        if (to == address(board)) donatedToBoard += amount;
    }

    function advanceTime(uint32 raw, uint8 boundary) public {
        uint256[6] memory edges = [uint256(0), 1, 599, 600, 86_399, 86_400];
        uint256 elapsed = boundary % 7 == 6 ? bound(raw, 0, 2 days) : edges[boundary % 7];
        vm.warp(vm.getBlockTimestamp() + elapsed);
    }

    function attemptReconfiguration(uint8 who, bool zero) public {
        address caller = actors[who % 4];
        vm.prank(caller);
        vm.expectRevert(caller == OWNER ? LastWord.TokenAlreadySet.selector : LastWord.Unauthorized.selector);
        board.setToken(zero ? address(0) : address(asset));
    }

    function expectedMinimum() public view returns (uint256) {
        LastWord.Message storage latest = _messages[_messages.length - 1];
        if (latest.burned == 0 || vm.getBlockTimestamp() >= latest.timestamp + 1 days) return BASE;
        // The fixed supply is 4e30, so this independent rational expression cannot overflow.
        return (latest.burned * 11 + 9) / 10;
    }

    function modelCount() external view returns (uint256) {
        return _messages.length;
    }

    function modelMessage(uint256 index) external view returns (LastWord.Message memory) {
        return _messages[index];
    }

    function _approve(address author, uint256 amount) private {
        vm.prank(author);
        asset.approve(address(board), amount);
        expectedAllowance[author] = amount;
    }

    function _paymentError(address author, uint256 amount) private view returns (bytes memory) {
        if (expectedAllowance[author] < amount) {
            return abi.encodeWithSelector(MockToken.InsufficientAllowance.selector);
        }
        if (expectedBalance[author] < amount) return abi.encodeWithSelector(MockToken.InsufficientBalance.selector);
        return "";
    }

    function _attempt(address author, string memory text, uint256 amount, bytes memory expectedError) private {
        if (expectedError.length == 0) {
            vm.expectEmit(true, false, false, true, address(board));
            emit MessageSet(author, text, amount, vm.getBlockTimestamp());
        }
        vm.prank(author);
        (bool success, bytes memory result) = address(board).call(abi.encodeCall(board.setMessage, (text, amount)));
        if (expectedError.length != 0) {
            assertFalse(success, "invalid post succeeded");
            assertEq(result, expectedError, "wrong rejection reason");
            ++rejectedPosts;
            return;
        }
        assertTrue(success, "funded, approved, valid post failed");
        expectedBalance[author] -= amount;
        expectedBalance[SINK] += amount;
        expectedAllowance[author] -= amount;
        burned += amount;
        ++successfulPaidPosts;
        _messages.push(LastWord.Message(author, text, amount, vm.getBlockTimestamp()));
    }

    function _text(uint256 kind) private pure returns (string memory) {
        kind %= 6;
        if (kind == 0) return "x";
        if (kind == 1) return _repeat("a", 31);
        if (kind == 2) return _repeat("b", 32);
        if (kind == 3) return _repeat("c", 33);
        if (kind == 4) return _repeat("d", 140);
        return _repeat(hex"f09f9880", 140);
    }

    function _repeat(bytes memory scalar, uint256 count) private pure returns (string memory) {
        bytes memory result = new bytes(scalar.length * count);
        for (uint256 i; i < result.length; ++i) {
            result[i] = scalar[i % scalar.length];
        }
        return string(result);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 128
/// forge-config: default.invariant.fail-on-revert = true
contract LastWordLedgerInvariantTest is Test {
    LastWord private board;
    MockToken private asset;
    LastWordLedgerHandler private handler;

    function setUp() public {
        vm.warp(1_000_000);
        board = new LastWord(address(bytes20(hex"b77161bbaf98470c6c5101899d30df413f9a019d")));
        asset = new MockToken(6);
        handler = new LastWordLedgerHandler(board, asset);
        // Every campaign starts with a wrapped paid post, an approval failure, and both donation kinds.
        handler.approveAndPost(0, 1, 5);
        handler.approve(1, 0, 0);
        handler.post(1, 0, 0);
        handler.transfer(2, 4, 1);
        handler.transfer(2, 5, 1);

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.approve.selector;
        selectors[1] = handler.post.selector;
        selectors[2] = handler.approveAndPost.selector;
        selectors[3] = handler.rejectPost.selector;
        selectors[4] = handler.transfer.selector;
        selectors[5] = handler.advanceTime.selector;
        selectors[6] = handler.attemptReconfiguration.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_fixedSupplyAndEveryActorsLedgerAreConserved() public view {
        uint256 tracked = asset.balanceOf(handler.SINK()) + asset.balanceOf(address(board));
        for (uint256 i; i < 4; ++i) {
            address actor = handler.actors(i);
            assertEq(asset.balanceOf(actor), handler.expectedBalance(actor), "actor balance");
            assertEq(asset.allowance(actor, address(board)), handler.expectedAllowance(actor), "actor allowance");
            tracked += asset.balanceOf(actor);
        }
        assertEq(tracked, 4 * handler.ENDOWMENT(), "conservation of all minted units");
        assertEq(asset.totalSupply(), tracked, "sink transfers must not change supply");
        assertEq(board.totalBurned(), handler.burned(), "only successful posts count as burns");
        assertEq(asset.balanceOf(handler.SINK()), handler.burned() + handler.donatedToSink());
        assertEq(asset.balanceOf(address(board)), handler.donatedToBoard(), "posting must not take custody");
        assertEq(asset.balanceOf(address(handler)), 0);
        assertEq(address(board).balance, 0);
    }

    function invariant_exactHistorySurvivesTransfersFailuresAndWraps() public view {
        uint256 count = handler.modelCount();
        assertEq(board.messageCount(), count);
        assertEq(board.historyCount(), 50);
        LastWord.Message[] memory recent = board.getRecentMessages();
        assertEq(recent.length, 50);
        for (uint256 i; i < 50; ++i) {
            bytes memory expected = abi.encode(handler.modelMessage(count - 50 + i));
            assertEq(abi.encode(recent[i]), expected, "history differs from accepted inputs");
            assertEq(abi.encode(board.getMessage(i)), expected, "indexed history differs");
        }
        assertEq(abi.encode(board.currentMessage()), abi.encode(handler.modelMessage(count - 1)));
    }

    function invariant_priceOwnerAndFreeCooldownsCannotBeChangedByUnrelatedActions() public view {
        assertEq(board.minimumBurn(), handler.expectedMinimum());
        assertEq(board.owner(), handler.OWNER());
        assertEq(board.token(), address(asset));
        assertEq(board.tokenDecimals(), 6);
        assertEq(board.baseMinimumBurn(), handler.BASE());
        for (uint256 i; i < 4; ++i) {
            address actor = handler.actors(i);
            assertEq(board.nextFreePostAt(actor), handler.expectedCooldown(actor));
        }
        assertGt(handler.successfulPaidPosts(), 0, "campaign must exercise paid mode");
        assertGt(handler.rejectedPosts(), 0, "campaign must exercise rejection");
    }

    function test_drainRevokeRejectRefundAndRetrySequence() public {
        uint256 rejectedBefore = handler.rejectedPosts();
        uint256 paidBefore = handler.successfulPaidPosts();
        // Drain Alice to Bob. Alice's freshly approved post must fail for insufficient balance.
        handler.transfer(0, 1, type(uint256).max);
        handler.approveAndPost(0, 0, 2);
        // Refill, revoke, fail for allowance, then approve and successfully replace the long string.
        handler.transfer(1, 0, 100 * handler.BASE());
        handler.approve(0, 0, 0);
        handler.post(0, 0, 2);
        handler.approveAndPost(0, 0, 2);
        handler.rejectPost(3, 0, 0);
        handler.advanceTime(0, 5);
        handler.approveAndPost(3, 0, 0);
        assertEq(handler.rejectedPosts(), rejectedBefore + 3);
        assertEq(handler.successfulPaidPosts(), paidBefore + 2);
        invariant_fixedSupplyAndEveryActorsLedgerAreConserved();
        invariant_exactHistorySurvivesTransfersFailuresAndWraps();
        invariant_priceOwnerAndFreeCooldownsCannotBeChangedByUnrelatedActions();
    }
}
