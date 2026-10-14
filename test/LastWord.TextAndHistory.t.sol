// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LastWordBase} from "./LastWordBase.sol";
import {LastWord} from "../src/LastWord.sol";

contract LastWordTextTest is LastWordBase {
    function test_emptyOrTooLongTextDoesNotConsumeFreeCooldown() public {
        vm.startPrank(alice);
        vm.expectRevert(LastWord.InvalidMessageLength.selector);
        board.setMessage("", 0);
        vm.expectRevert(LastWord.InvalidMessageLength.selector);
        board.setMessage(_repeat("a", 141), 0);
        vm.expectRevert(LastWord.InvalidMessageLength.selector);
        board.setMessage(_repeat(hex"f09f9880", 141), 0);
        vm.stopPrank();
        assertEq(board.nextFreePostAt(alice), 0);
        assertEq(board.messageCount(), 0);
        _post(alice, "Valid retry", 0);
    }

    function test_fullLengthAsciiAndEmojiAreAccepted() public {
        string memory ascii = _repeat("a", 140);
        string memory emoji = _repeat(hex"f09f9880", 140);
        _post(alice, ascii, 0);
        _post(bob, emoji, 0);
        assertEq(board.getMessage(0).text, ascii);
        assertEq(board.getMessage(1).text, emoji);
        assertEq(bytes(board.currentMessage().text).length, 560);
    }

    function test_mixedLanguagesAndCombiningMarksUseCodePoints() public {
        string memory mixed = unicode"Hello, café — 世界 🌍";
        _post(alice, mixed, 0);
        assertEq(board.currentMessage().text, mixed);
        // U+0065 followed by U+0301 is two code points, even though displayed as one grapheme.
        string memory accents = _repeat(hex"65cc81", 70);
        _post(bob, accents, 0);
        vm.warp(vm.getBlockTimestamp() + 600);
        vm.prank(bob);
        vm.expectRevert(LastWord.InvalidMessageLength.selector);
        board.setMessage(string.concat(accents, "e"), 0);
    }

    function test_utf8BoundaryScalarsAcceptedWithoutNormalization() public {
        bytes memory boundaries = hex"007fc280dfbfe0a080ed9fbfee8080efbfbff0908080f48fbfbf";
        _post(alice, string(boundaries), 0);
        assertEq(bytes(board.currentMessage().text), boundaries);
    }

    function test_invalidUtf8SequencesAreRejected() public {
        bytes[] memory invalid = new bytes[](18);
        invalid[0] = hex"80"; // Lone continuation.
        invalid[1] = hex"bf";
        invalid[2] = hex"c080"; // Overlong encoding of U+0000.
        invalid[3] = hex"c1bf";
        invalid[4] = hex"c2"; // Truncated two-byte sequence.
        invalid[5] = hex"c220"; // Non-continuation.
        invalid[6] = hex"e09fbf"; // Overlong three-byte sequence.
        invalid[7] = hex"eda080"; // UTF-16 surrogate.
        invalid[8] = hex"edbfbf";
        invalid[9] = hex"e280"; // Truncated three-byte sequence.
        invalid[10] = hex"e28020";
        invalid[11] = hex"f08fbfbf"; // Overlong four-byte sequence.
        invalid[12] = hex"f4908080"; // Above U+10FFFF.
        invalid[13] = hex"f5808080";
        invalid[14] = hex"f09080"; // Truncated four-byte sequence.
        invalid[15] = hex"f0908020";
        invalid[16] = hex"fe";
        invalid[17] = hex"ff";
        for (uint256 i; i < invalid.length; ++i) {
            vm.prank(alice);
            vm.expectRevert(LastWord.InvalidUtf8.selector);
            board.setMessage(string(invalid[i]), 0);
            assertEq(board.messageCount(), 0);
            assertEq(board.nextFreePostAt(alice), 0);
        }
    }

    function test_invalidPaidTextDoesNotSpendOrChangeState() public {
        _connect();
        _fundAndApprove(alice, BASE);
        bytes32 beforeState = _snapshot();
        bytes memory invalid = hex"eda080";
        vm.prank(alice);
        vm.expectRevert(LastWord.InvalidUtf8.selector);
        board.setMessage(string(invalid), BASE);
        assertEq(_snapshot(), beforeState);
        assertEq(asset.balanceOf(alice), BASE);
        assertEq(asset.allowance(alice, address(board)), BASE);
        assertEq(asset.balanceOf(sink), 0);
    }

    function testFuzz_validUnicodeScalarsPreserved(uint32 scalar, uint8 count) public {
        uint256 codePoint = bound(scalar, 0, 0x10ffff);
        // Map the surrogate range to valid private-use scalar values.
        if (codePoint >= 0xd800 && codePoint <= 0xdfff) codePoint += 0x800;
        uint256 length = bound(count, 1, 140);
        bytes memory encoded;
        if (codePoint <= 0x7f) {
            encoded = abi.encodePacked(uint8(codePoint));
        } else if (codePoint <= 0x7ff) {
            encoded = abi.encodePacked(uint8(0xc0 | codePoint >> 6), uint8(0x80 | codePoint & 0x3f));
        } else if (codePoint <= 0xffff) {
            encoded = abi.encodePacked(
                uint8(0xe0 | codePoint >> 12), uint8(0x80 | codePoint >> 6 & 0x3f), uint8(0x80 | codePoint & 0x3f)
            );
        } else {
            encoded = abi.encodePacked(
                uint8(0xf0 | codePoint >> 18),
                uint8(0x80 | codePoint >> 12 & 0x3f),
                uint8(0x80 | codePoint >> 6 & 0x3f),
                uint8(0x80 | codePoint & 0x3f)
            );
        }
        string memory text = _repeat(encoded, length);
        _post(alice, text, 0);
        assertEq(board.currentMessage().text, text);
    }

    function testFuzz_oversizeAsciiRejected(uint16 length) public {
        length = uint16(bound(length, 141, 600));
        string memory text = _repeat("x", length);
        vm.prank(alice);
        vm.expectRevert(LastWord.InvalidMessageLength.selector);
        board.setMessage(text, 0);
        assertEq(board.messageCount(), 0);
    }
}

contract LastWordHistoryTest is LastWordBase {
    function test_emptyHistoryHasNoValidIndex() public {
        vm.expectRevert(LastWord.HistoryIndexOutOfBounds.selector);
        board.getMessage(0);
    }

    function test_ringRetainsExactlyLastFiftyInChronologicalOrderAcrossMultipleWraps() public {
        uint256 start = vm.getBlockTimestamp();
        for (uint256 i; i < 153; ++i) {
            vm.warp(start + i * 600);
            _post(i % 2 == 0 ? alice : bob, vm.toString(i), 0);
            assertEq(board.historyCount(), i < 50 ? i + 1 : 50);
            assertEq(board.currentMessage().text, vm.toString(i));
        }
        assertEq(board.messageCount(), 153);
        LastWord.Message[] memory recent = board.getRecentMessages();
        assertEq(recent.length, 50);
        for (uint256 i; i < 50; ++i) {
            uint256 originalIndex = 103 + i;
            address author = originalIndex % 2 == 0 ? alice : bob;
            _assertMessage(recent[i], author, vm.toString(originalIndex), 0, start + originalIndex * 600);
            assertEq(abi.encode(board.getMessage(i)), abi.encode(recent[i]));
        }
        vm.expectRevert(LastWord.HistoryIndexOutOfBounds.selector);
        board.getMessage(50);
        vm.expectRevert(LastWord.HistoryIndexOutOfBounds.selector);
        board.getMessage(type(uint256).max);
    }

    function test_wrappingReplacesLongStorageStringsWithoutStaleSuffix() public {
        _post(alice, _repeat(hex"f09f9880", 140), 0);
        for (uint256 i = 1; i <= 50; ++i) {
            vm.warp(vm.getBlockTimestamp() + 600);
            _post(alice, "x", 0);
        }
        assertEq(board.currentMessage().text, "x");
        assertEq(board.getMessage(49).text, "x");
        assertEq(board.historyCount(), 50);
    }

    function test_totalBurnedIncludesPaidMessagesEvictedFromHistory() public {
        _connect();
        _fundAndApprove(alice, BASE * 75);
        for (uint256 i; i < 75; ++i) {
            vm.warp(vm.getBlockTimestamp() + 24 hours);
            _post(alice, vm.toString(i), BASE);
        }
        uint256 retainedBurns;
        LastWord.Message[] memory recent = board.getRecentMessages();
        for (uint256 i; i < recent.length; ++i) {
            retainedBurns += recent[i].burned;
        }
        assertEq(board.messageCount(), 75);
        assertEq(retainedBurns, BASE * 50);
        assertEq(board.totalBurned(), BASE * 75);
        assertEq(asset.balanceOf(sink), BASE * 75);
    }
}
