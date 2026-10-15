// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LastWordBase} from "./LastWordBase.sol";
import {LastWord} from "src/LastWord.sol";

/// @dev Extends the existing uint128 arithmetic campaign to the entire uint256 domain.
/// forge-config: default.fuzz.runs = 2048
contract LastWordFullWidthPricingTest is LastWordBase {
    // floor(MAX_UINT256 * 10 / 11), evaluated without overflowing an intermediate product.
    uint256 private constant LAST_ESCALATABLE = (type(uint256).max / 11) * 10 + ((type(uint256).max % 11) * 10) / 11;

    function setUp() public override {
        super.setUp();
        _connect();
    }

    function testFuzz_fullWidthQuoteIsTheLeastIntegerAtLeastTenPercentHigher(uint256 raw) public {
        uint256 amount = bound(raw, BASE, LAST_ESCALATABLE);
        _checkRepresentableQuote(amount);
    }

    function test_largestRepresentableEscalation() public {
        _checkRepresentableQuote(LAST_ESCALATABLE);
    }

    function test_oneUnitBeyondEscalationLimit() public {
        _checkUnrepresentableQuote(LAST_ESCALATABLE + 1);
    }

    function test_fullTokenSupplyCanBeBurnedWithoutIntermediateMultiplicationOverflow() public {
        _checkUnrepresentableQuote(type(uint256).max);
    }

    function testFuzz_unrepresentableEscalationRejectsUntilExactResetBoundary(uint256 raw) public {
        _checkUnrepresentableQuote(bound(raw, LAST_ESCALATABLE + 1, type(uint256).max));
    }

    function _checkRepresentableQuote(uint256 amount) private {
        _fundAndApprove(alice, amount);
        _post(alice, "Full-width amount", amount);
        uint256 next = board.minimumBurn();
        // Check the defining inequalities using full 512-bit products, independently of the
        // contract's quotient/remainder implementation: 10*(next-1) < 11*amount <= 10*next.
        (uint256 targetHi, uint256 targetLo) = _product(amount, 11);
        (uint256 upperHi, uint256 upperLo) = _product(next, 10);
        (uint256 lowerHi, uint256 lowerLo) = _product(next - 1, 10);
        assertTrue(upperHi > targetHi || (upperHi == targetHi && upperLo >= targetLo), "quote undercharges");
        assertTrue(lowerHi < targetHi || (lowerHi == targetHi && lowerLo < targetLo), "quote rounds too far up");
        assertEq(board.totalBurned(), amount);
        assertEq(asset.balanceOf(sink), amount);
        assertEq(asset.balanceOf(alice), 0);
        assertEq(asset.allowance(alice, address(board)), 0);
    }

    function _checkUnrepresentableQuote(uint256 amount) private {
        _fundAndApprove(alice, amount);
        _post(alice, "Overflowing next quote", amount);
        bytes memory beforeHistory = abi.encode(board.getRecentMessages());
        uint256 timestamp = vm.getBlockTimestamp();
        vm.warp(timestamp + 1 days - 1);
        vm.expectRevert(LastWord.MinimumBurnOverflow.selector);
        board.minimumBurn();
        vm.prank(bob);
        vm.expectRevert(LastWord.MinimumBurnOverflow.selector);
        board.setMessage("Cannot sneak through with zero", 0);
        assertEq(abi.encode(board.getRecentMessages()), beforeHistory);
        assertEq(board.messageCount(), 1);
        assertEq(board.totalBurned(), amount);
        assertEq(asset.balanceOf(sink), amount);
        vm.warp(timestamp + 1 days);
        assertEq(board.minimumBurn(), BASE, "inactivity restores a representable quote");
        assertEq(abi.encode(board.getRecentMessages()), beforeHistory);
    }

    function _product(uint256 value, uint256 factor) private pure returns (uint256 hi, uint256 lo) {
        assembly ("memory-safe") {
            let residue := mulmod(value, factor, not(0))
            lo := mul(value, factor)
            hi := sub(sub(residue, lo), lt(residue, lo))
        }
    }
}

/// forge-config: default.fuzz.runs = 1024
contract LastWordTextBoundaryPropertiesTest is LastWordBase {
    function testFuzz_mixedWidthTextAccepts140CodePointsAndRejects141(uint8 rawTwo, uint8 rawThree, uint8 rawFour)
        public
    {
        uint256 two = bound(rawTwo, 0, 140);
        uint256 three = bound(rawThree, 0, 140 - two);
        uint256 four = bound(rawFour, 0, 140 - two - three);
        string memory text = string.concat(
            _repeat("a", 140 - two - three - four),
            _repeat(hex"c2a2", two),
            _repeat(hex"e282ac", three),
            _repeat(hex"f09f9880", four)
        );
        _post(alice, text, 0);
        bytes32 beforeState = _snapshot();
        vm.prank(bob);
        vm.expectRevert(LastWord.InvalidMessageLength.selector);
        board.setMessage(string.concat(text, "!"), 0);
        assertEq(_snapshot(), beforeState);
        _post(bob, text, 0);
        assertEq(board.currentMessage().text, text);
    }

    function testFuzz_truncatedMultibyteSuffixCannotConsumePaidApproval(uint8 rawPrefix, uint8 rawWidth, uint8 rawCut)
        public
    {
        _connect();
        _fundAndApprove(alice, 3 * BASE);
        _post(alice, "Existing paid text", BASE);
        uint256 width = bound(rawWidth, 2, 4);
        uint256 cut = bound(rawCut, 1, width - 1);
        bytes memory scalar = width == 2 ? bytes(hex"c2a2") : width == 3 ? bytes(hex"e282ac") : bytes(hex"f09f9880");
        bytes memory truncated = new bytes(cut);
        for (uint256 i; i < cut; ++i) {
            truncated[i] = scalar[i];
        }
        string memory text = string.concat(_repeat("a", bound(rawPrefix, 0, 139)), string(truncated));
        _rejectPaidTextAndRetry(text);
    }

    function testFuzz_invalidContinuationAtAnyBytePositionIsRejected(uint8 rawPrefix, uint8 rawPosition, uint8 rawBad)
        public
    {
        _connect();
        _fundAndApprove(alice, 3 * BASE);
        _post(alice, "Existing paid text", BASE);
        bytes memory scalar = hex"f09f9880";
        uint256 position = bound(rawPosition, 1, 3);
        // A continuation must be 0x80..0xbf. This mapping exercises both sides of that range.
        uint256 invalidByte = bound(rawBad, 0, 191);
        if (invalidByte >= 128) invalidByte += 64;
        scalar[position] = bytes1(uint8(invalidByte));
        string memory text = string.concat(_repeat("a", bound(rawPrefix, 0, 139)), string(scalar));
        _rejectPaidTextAndRetry(text);
    }

    function test_eachUtf8WidthCanEndAtThe140thCharacter() public {
        bytes[4] memory scalars = [bytes(hex"7f"), bytes(hex"dfbf"), bytes(hex"efbfbf"), bytes(hex"f48fbfbf")];
        for (uint256 i; i < scalars.length; ++i) {
            vm.warp(vm.getBlockTimestamp() + 600);
            string memory text = string.concat(_repeat("x", 139), string(scalars[i]));
            _post(alice, text, 0);
            assertEq(board.currentMessage().text, text);
        }
    }

    function _rejectPaidTextAndRetry(string memory text) private {
        bytes32 beforeState = _snapshot();
        uint256 balance = asset.balanceOf(alice);
        uint256 allowance = asset.allowance(alice, address(board));
        uint256 amount = board.minimumBurn();
        vm.prank(alice);
        vm.expectRevert(LastWord.InvalidUtf8.selector);
        board.setMessage(text, amount);
        assertEq(_snapshot(), beforeState);
        assertEq(asset.balanceOf(alice), balance);
        assertEq(asset.allowance(alice, address(board)), allowance);
        assertEq(asset.balanceOf(sink), BASE);
        _post(alice, "Valid retry", amount);
        assertEq(board.totalBurned(), BASE + amount);
        assertEq(asset.balanceOf(sink), BASE + amount);
    }
}
