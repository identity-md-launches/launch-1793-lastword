// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LastWord} from "../src/LastWord.sol";
import {MockToken} from "./mocks/MockToken.sol";

abstract contract LastWordBase is Test {
    address internal constant OWNER = address(bytes20(hex"b77161bbaf98470c6c5101899d30df413f9a019d"));
    uint256 internal constant BASE = 1_000 ether;
    LastWord internal board;
    MockToken internal asset;
    address internal alice;
    address internal bob;
    address internal sink;

    event TokenSet(address indexed token);
    event MessageSet(address indexed author, string text, uint256 burned, uint256 timestamp);

    function setUp() public virtual {
        vm.warp(1_000_000);
        alice = makeAddr("test-alice");
        bob = makeAddr("test-bob");
        board = new LastWord(OWNER);
        asset = new MockToken(18);
        sink = board.BURN_ADDRESS();
    }

    function _connect() internal {
        vm.prank(OWNER);
        board.setToken(address(asset));
    }

    function _fundAndApprove(address author, uint256 amount) internal {
        asset.mint(author, amount);
        vm.prank(author);
        asset.approve(address(board), amount);
    }

    function _post(address author, string memory text, uint256 amount) internal {
        vm.prank(author);
        board.setMessage(text, amount);
    }

    function _assertMessage(
        LastWord.Message memory message,
        address author,
        string memory text,
        uint256 burned,
        uint256 timestamp
    ) internal pure {
        assertEq(message.author, author);
        assertEq(message.text, text);
        assertEq(message.burned, burned);
        assertEq(message.timestamp, timestamp);
    }

    function _snapshot() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                board.getRecentMessages(),
                board.currentMessage(),
                board.totalBurned(),
                board.messageCount(),
                board.minimumBurn(),
                board.nextFreePostAt(alice),
                board.nextFreePostAt(bob)
            )
        );
    }

    function _repeat(bytes memory character, uint256 count) internal pure returns (string memory) {
        bytes memory text = new bytes(character.length * count);
        for (uint256 i; i < count; ++i) {
            for (uint256 j; j < character.length; ++j) {
                text[i * character.length + j] = character[j];
            }
        }
        return string(text);
    }
}
