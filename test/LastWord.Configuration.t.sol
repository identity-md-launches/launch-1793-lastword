// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LastWordBase} from "./LastWordBase.sol";
import {LastWord} from "../src/LastWord.sol";
import {MockToken, NoMetadataToken, RevertingMetadataToken} from "./mocks/MockToken.sol";

contract TestDeploymentFactory {
    function deploy(address owner) external returns (LastWord) {
        return new LastWord{salt: keccak256("lastword-test")}(owner);
    }
}

contract LastWordConfigurationTest is LastWordBase {
    function test_initialStateAndExplicitOwner() public view {
        assertEq(board.owner(), OWNER);
        assertNotEq(board.owner(), address(this));
        assertEq(board.token(), address(0));
        assertEq(board.baseMinimumBurn(), 0);
        assertEq(board.minimumBurn(), 0);
        assertEq(board.totalBurned(), 0);
        assertEq(board.messageCount(), 0);
        assertEq(board.historyCount(), 0);
        assertEq(board.getRecentMessages().length, 0);
        _assertMessage(board.currentMessage(), address(0), "", 0, 0);
    }

    function test_constructorRejectsZeroOwner() public {
        vm.expectRevert(LastWord.InvalidOwner.selector);
        new LastWord(address(0));
    }

    function test_factoryAndOriginHaveNoRights() public {
        TestDeploymentFactory factory = new TestDeploymentFactory();
        vm.prank(alice, bob);
        LastWord deployed = factory.deploy(OWNER);
        assertEq(deployed.owner(), OWNER);
        vm.prank(address(factory));
        vm.expectRevert(LastWord.Unauthorized.selector);
        deployed.setToken(address(asset));
        vm.prank(bob);
        vm.expectRevert(LastWord.Unauthorized.selector);
        deployed.setToken(address(asset));
        vm.prank(OWNER);
        deployed.setToken(address(asset));
        assertEq(deployed.token(), address(asset));
    }

    function test_setTokenEmitsAndIsPermanent() public {
        vm.expectEmit(true, false, false, true, address(board));
        emit TokenSet(address(asset));
        _connect();
        assertEq(board.token(), address(asset));
        assertEq(board.tokenDecimals(), 18);
        assertEq(board.baseMinimumBurn(), BASE);
        assertEq(board.minimumBurn(), BASE);

        MockToken other = new MockToken(6);
        vm.startPrank(OWNER);
        vm.expectRevert(LastWord.TokenAlreadySet.selector);
        board.setToken(address(other));
        vm.expectRevert(LastWord.TokenAlreadySet.selector);
        board.setToken(address(asset));
        vm.expectRevert(LastWord.TokenAlreadySet.selector);
        board.setToken(address(0));
        vm.stopPrank();
        assertEq(board.token(), address(asset));
    }

    function test_unauthorizedCannotConnectOrChangeToken() public {
        vm.prank(alice);
        vm.expectRevert(LastWord.Unauthorized.selector);
        board.setToken(address(asset));
        assertEq(board.token(), address(0));
        _connect();
        vm.prank(bob);
        vm.expectRevert(LastWord.Unauthorized.selector);
        board.setToken(address(asset));
    }

    function test_invalidTokenDoesNotConsumeSlot() public {
        NoMetadataToken noMetadata = new NoMetadataToken();
        RevertingMetadataToken revertingMetadata = new RevertingMetadataToken();
        MockToken tooManyDecimals = new MockToken(75);
        vm.startPrank(OWNER);
        vm.expectRevert(LastWord.InvalidToken.selector);
        board.setToken(address(0));
        vm.expectRevert(LastWord.InvalidToken.selector);
        board.setToken(alice);
        vm.expectRevert(LastWord.InvalidTokenDecimals.selector);
        board.setToken(address(noMetadata));
        vm.expectRevert(LastWord.InvalidTokenDecimals.selector);
        board.setToken(address(revertingMetadata));
        vm.expectRevert(LastWord.InvalidTokenDecimals.selector);
        board.setToken(address(tooManyDecimals));
        vm.stopPrank();
        assertEq(board.token(), address(0));
        assertEq(board.baseMinimumBurn(), 0);
        _post(alice, "Still free", 0);
        _connect();
        assertEq(board.minimumBurn(), BASE);
    }

    function testFuzz_decimalsScaleOneThousandWholeTokens(uint8 decimals_) public {
        decimals_ = uint8(bound(decimals_, 0, 74));
        asset = new MockToken(decimals_);
        uint256 amount = 1_000 * 10 ** uint256(decimals_);
        _connect();
        assertEq(board.tokenDecimals(), decimals_);
        assertEq(board.minimumBurn(), amount);
        _fundAndApprove(alice, amount);
        _post(alice, "Scaled correctly", amount);
        assertEq(asset.balanceOf(sink), amount);
        assertEq(board.totalBurned(), amount);
    }

    function testFuzz_unsupportedDecimalsLeaveFreeMode(uint8 decimals_) public {
        decimals_ = uint8(bound(decimals_, 75, 255));
        MockToken unsupported = new MockToken(decimals_);
        vm.prank(OWNER);
        vm.expectRevert(LastWord.InvalidTokenDecimals.selector);
        board.setToken(address(unsupported));
        assertEq(board.token(), address(0));
        _post(alice, "Still free", 0);
    }

    function test_noEthAcceptedByPostTokenSetterOrFallback() public {
        vm.deal(alice, 1 ether);
        vm.startPrank(alice);
        (bool receiveSuccess,) = address(board).call{value: 1}("");
        (bool postSuccess,) = address(board).call{value: 1}(abi.encodeCall(board.setMessage, ("ETH rejected", 0)));
        (bool setterSuccess,) = address(board).call{value: 1}(abi.encodeCall(board.setToken, (address(asset))));
        (bool fallbackSuccess,) = address(board).call(hex"deadbeef");
        vm.stopPrank();
        assertFalse(receiveSuccess);
        assertFalse(postSuccess);
        assertFalse(setterSuccess);
        assertFalse(fallbackSuccess);
        assertEq(address(board).balance, 0);
        assertEq(board.messageCount(), 0);
    }

    function test_runtimeBoundedAndContainsNoForbiddenOpcodes() public view {
        bytes memory code = address(board).code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 opcode = uint8(code[i]);
            if (opcode >= 0x60 && opcode <= 0x7f) {
                i += opcode - 0x5f;
                continue;
            }
            assertTrue(opcode != 0xf4 && opcode != 0xf2 && opcode != 0xff, "forbidden opcode");
        }
    }
}
