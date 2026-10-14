// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LastWord} from "../src/LastWord.sol";
import {MockToken} from "./mocks/MockToken.sol";

/// @dev Stateful reference model: transactions interleave free/paid posts, configuration,
///      invalid bids and arbitrary forward time. Reverts outside expected failures fail the suite.
contract LastWordHandler is Test {
    address public constant OWNER = address(bytes20(hex"b77161bbaf98470c6c5101899d30df413f9a019d"));
    uint256 private constant BASE = 1_000 ether;
    LastWord public immutable board;
    MockToken public immutable asset;
    address[3] public actors;
    LastWord.Message[] private _model;
    mapping(address => uint256) public modelNextFreePostAt;
    bool public connected;
    uint256 public modelBurned;
    uint256 public rejectedPosts;

    constructor(LastWord board_, MockToken asset_) {
        board = board_;
        asset = asset_;
        actors[0] = makeAddr("invariant-alice");
        actors[1] = makeAddr("invariant-bob");
        actors[2] = makeAddr("invariant-carol");
    }

    function advanceTime(uint32 elapsed) external {
        vm.warp(vm.getBlockTimestamp() + bound(elapsed, 0, 2 days));
    }

    function connectToken() external {
        if (connected) return;
        vm.prank(OWNER);
        board.setToken(address(asset));
        connected = true;
    }

    function freePost(uint8 who) external {
        if (connected) return;
        address author = actors[who % 3];
        string memory text = string.concat("free-", vm.toString(_model.length));
        uint256 available = modelNextFreePostAt[author];
        if (vm.getBlockTimestamp() < available) {
            vm.prank(author);
            vm.expectRevert(abi.encodeWithSelector(LastWord.CooldownActive.selector, available));
            board.setMessage(text, 0);
            ++rejectedPosts;
            return;
        }
        vm.prank(author);
        board.setMessage(text, 0);
        modelNextFreePostAt[author] = vm.getBlockTimestamp() + 600;
        _model.push(LastWord.Message(author, text, 0, vm.getBlockTimestamp()));
    }

    function paidPost(uint8 who, uint96 extra) external {
        if (!connected) return;
        address author = actors[who % 3];
        uint256 amount = modelMinimum() + bound(extra, 0, BASE);
        string memory text = string.concat("paid-", vm.toString(_model.length));
        asset.mint(author, amount);
        vm.startPrank(author);
        asset.approve(address(board), amount);
        board.setMessage(text, amount);
        vm.stopPrank();
        modelBurned += amount;
        _model.push(LastWord.Message(author, text, amount, vm.getBlockTimestamp()));
    }

    function underpay(uint8 who, uint96 amount) external {
        if (!connected) return;
        uint256 minimum = modelMinimum();
        uint256 supplied = bound(amount, 0, minimum - 1);
        vm.prank(actors[who % 3]);
        vm.expectRevert(abi.encodeWithSelector(LastWord.BurnTooSmall.selector, minimum, supplied));
        board.setMessage("must fail", supplied);
        ++rejectedPosts;
    }

    function unauthorizedConfiguration(uint8 who) external {
        vm.prank(actors[who % 3]);
        vm.expectRevert(LastWord.Unauthorized.selector);
        board.setToken(address(asset));
    }

    function modelCount() external view returns (uint256) {
        return _model.length;
    }

    function modelMessage(uint256 index) external view returns (LastWord.Message memory) {
        return _model[index];
    }

    function modelMinimum() public view returns (uint256) {
        if (!connected) return 0;
        if (_model.length == 0) return BASE;
        LastWord.Message storage last = _model[_model.length - 1];
        if (last.burned == 0 || vm.getBlockTimestamp() >= last.timestamp + 86_400) return BASE;
        // Independent formula; the handler's bounded amounts/depth cannot approach overflow.
        return (last.burned * 11 + 9) / 10;
    }
}

contract LastWordInvariantTest is Test {
    LastWord private board;
    MockToken private asset;
    LastWordHandler private handler;

    function setUp() public {
        vm.warp(1_000_000);
        address owner = address(bytes20(hex"b77161bbaf98470c6c5101899d30df413f9a019d"));
        board = new LastWord(owner);
        asset = new MockToken(18);
        handler = new LastWordHandler(board, asset);
        handler.freePost(0);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.advanceTime.selector;
        selectors[1] = handler.connectToken.selector;
        selectors[2] = handler.freePost.selector;
        selectors[3] = handler.paidPost.selector;
        selectors[4] = handler.underpay.selector;
        selectors[5] = handler.unauthorizedConfiguration.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_historyAndCurrentMessageMatchChronologicalModel() public view {
        uint256 count = handler.modelCount();
        assertEq(board.messageCount(), count);
        uint256 retained = count < 50 ? count : 50;
        assertEq(board.historyCount(), retained);
        LastWord.Message[] memory recent = board.getRecentMessages();
        assertEq(recent.length, retained);
        for (uint256 i; i < retained; ++i) {
            bytes memory expected = abi.encode(handler.modelMessage(count - retained + i));
            assertEq(abi.encode(recent[i]), expected);
            assertEq(abi.encode(board.getMessage(i)), expected);
        }
        assertEq(abi.encode(board.currentMessage()), abi.encode(handler.modelMessage(count - 1)));
    }

    function invariant_allPaidTokensReachSinkWithoutCustodyOrFees() public view {
        assertEq(board.totalBurned(), handler.modelBurned());
        assertEq(asset.balanceOf(board.BURN_ADDRESS()), handler.modelBurned());
        assertEq(asset.totalSupply(), handler.modelBurned());
        assertEq(asset.balanceOf(address(board)), 0);
        assertEq(asset.balanceOf(handler.OWNER()), 0);
        assertEq(address(board).balance, 0);
        for (uint256 i; i < 3; ++i) {
            assertEq(asset.balanceOf(handler.actors(i)), 0);
            assertEq(asset.allowance(handler.actors(i), address(board)), 0);
        }
    }

    function invariant_pricingCooldownsAndConfigurationMatchModel() public view {
        assertEq(board.minimumBurn(), handler.modelMinimum());
        assertEq(board.owner(), handler.OWNER());
        assertEq(board.token(), handler.connected() ? address(asset) : address(0));
        assertEq(board.baseMinimumBurn(), handler.connected() ? 1_000 ether : 0);
        for (uint256 i; i < 3; ++i) {
            address actor = handler.actors(i);
            assertEq(board.nextFreePostAt(actor), handler.modelNextFreePostAt(actor));
        }
    }
}
