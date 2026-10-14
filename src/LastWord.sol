// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title LastWord
/// @notice A public billboard, free until its owner permanently connects the project's ERC-20.
/// @dev Burns mean transfers to BURN_ADDRESS, not a reduction in the ERC-20's totalSupply.
contract LastWord is ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Message {
        address author;
        string text;
        uint256 burned;
        uint256 timestamp;
    }

    uint256 public constant MAX_CHARACTERS = 140;
    uint256 public constant HISTORY_LIMIT = 50;
    uint256 public constant FREE_COOLDOWN = 10 minutes;
    uint256 public constant RESET_INTERVAL = 24 hours;
    uint256 public constant BASE_TOKENS = 1_000;
    uint8 public constant MAX_TOKEN_DECIMALS = 74;
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @notice Immutable creator; the only privileged operation is the one-time setToken call.
    address public immutable owner;
    /// @notice Zero until the owner connects the project's token. It cannot subsequently change.
    address public token;
    uint8 public tokenDecimals;
    /// @notice The 1,000-token floor in base units; zero until setToken succeeds.
    uint256 public baseMinimumBurn;
    uint256 public totalBurned;
    /// @notice Lifetime count, including free posts; only the most recent 50 remain in storage.
    uint256 public messageCount;
    /// @notice Earliest timestamp for this address's next free post; unused in paid mode.
    mapping(address author => uint256 timestamp) public nextFreePostAt;

    Message[50] private _messages;

    event TokenSet(address indexed token);
    event MessageSet(address indexed author, string text, uint256 burned, uint256 timestamp);

    error InvalidOwner();
    error Unauthorized();
    error TokenAlreadySet();
    error InvalidToken();
    error InvalidTokenDecimals();
    error InvalidMessageLength();
    error InvalidUtf8();
    error FreePostRequiresZeroBurn();
    error CooldownActive(uint256 availableAt);
    error BurnTooSmall(uint256 minimum, uint256 supplied);
    error BurnAmountMismatch();
    error MinimumBurnOverflow();
    error HistoryIndexOutOfBounds();

    /// @param initialOwner Creator wallet, supplied explicitly because deployment uses a factory.
    constructor(address initialOwner) {
        if (initialOwner == address(0)) revert InvalidOwner();
        owner = initialOwner;
    }

    /// @notice Permanently enables paid posting with the project's ERC-20.
    /// @dev The owner must verify the address and token behavior before calling. Metadata is read
    ///      here, never in the constructor. Supports 0..74 decimals and exact, non-rebasing transfers.
    function setToken(address newToken) external nonReentrant {
        if (msg.sender != owner) revert Unauthorized();
        if (token != address(0)) revert TokenAlreadySet();
        if (newToken == address(0) || newToken.code.length == 0) revert InvalidToken();

        uint8 decimals = 0;
        try IERC20Metadata(newToken).decimals() returns (uint8 result) {
            decimals = result;
        } catch {
            revert InvalidTokenDecimals();
        }
        if (decimals > MAX_TOKEN_DECIMALS) revert InvalidTokenDecimals();

        token = newToken;
        tokenDecimals = decimals;
        baseMinimumBurn = BASE_TOKENS * 10 ** uint256(decimals);
        emit TokenSet(newToken);
    }

    /// @notice Replace the billboard with 1..140 valid UTF-8 code points (not grapheme clusters).
    /// @param text New public text, including when identical to the previous text.
    /// @param burnAmount Exact base units to transfer from the caller to BURN_ADDRESS. Must be zero
    ///        before token connection and at least minimumBurn() afterwards. Approve this contract first.
    function setMessage(string calldata text, uint256 burnAmount) external nonReentrant {
        _validateText(bytes(text));

        address connectedToken = token;
        if (connectedToken == address(0)) {
            if (burnAmount != 0) revert FreePostRequiresZeroBurn();
            uint256 availableAt = nextFreePostAt[msg.sender];
            if (block.timestamp < availableAt) revert CooldownActive(availableAt);
            nextFreePostAt[msg.sender] = block.timestamp + FREE_COOLDOWN;
        } else {
            uint256 minimum = minimumBurn();
            if (burnAmount < minimum) revert BurnTooSmall(minimum, burnAmount);
            totalBurned += burnAmount;
        }

        _messages[messageCount % HISTORY_LIMIT] = Message(msg.sender, text, burnAmount, block.timestamp);
        ++messageCount;

        if (connectedToken != address(0)) {
            IERC20 asset = IERC20(connectedToken);
            uint256 beforeBalance = asset.balanceOf(BURN_ADDRESS);
            asset.safeTransferFrom(msg.sender, BURN_ADDRESS, burnAmount);
            uint256 afterBalance = asset.balanceOf(BURN_ADDRESS);
            // Reject fake-success and fee-on-transfer tokens; all preceding effects roll back.
            if (afterBalance < beforeBalance || afterBalance - beforeBalance != burnAmount) {
                revert BurnAmountMismatch();
            }
        }

        emit MessageSet(msg.sender, text, burnAmount, block.timestamp);
    }

    /// @notice Minimum required now, in token base units; zero while posting is free.
    /// @dev A paid post sets the next minimum to ceil(previous actual burn * 1.1).
    ///      Exactly 24 hours after the last post, the floor is restored without a transaction.
    ///      If escalation exceeds uint256, paid posting must wait for that reset.
    function minimumBurn() public view returns (uint256) {
        if (token == address(0)) return 0;
        if (messageCount == 0) return baseMinimumBurn;
        Message storage latest = _messages[(messageCount - 1) % HISTORY_LIMIT];
        if (latest.burned == 0 || block.timestamp - latest.timestamp >= RESET_INTERVAL) {
            return baseMinimumBurn;
        }

        uint256 increase = latest.burned / 10;
        if (latest.burned % 10 != 0) ++increase;
        if (latest.burned > type(uint256).max - increase) revert MinimumBurnOverflow();
        return latest.burned + increase;
    }

    /// @notice Latest message; all fields are empty/zero before the first post.
    function currentMessage() external view returns (Message memory) {
        return _messages[messageCount == 0 ? 0 : (messageCount - 1) % HISTORY_LIMIT];
    }

    /// @notice Number of messages currently retained (0..50).
    function historyCount() public view returns (uint256) {
        return messageCount < HISTORY_LIMIT ? messageCount : HISTORY_LIMIT;
    }

    /// @notice Read a retained message by index, oldest = 0 and newest = historyCount() - 1.
    /// @dev Indices shift as new posts arrive. Use a fixed block tag for consistent multi-call reads.
    function getMessage(uint256 index) public view returns (Message memory) {
        if (index >= historyCount()) revert HistoryIndexOutOfBounds();
        uint256 start = messageCount > HISTORY_LIMIT ? messageCount % HISTORY_LIMIT : 0;
        return _messages[(start + index) % HISTORY_LIMIT];
    }

    /// @notice All retained messages in chronological order, oldest first, in one consistent read.
    function getRecentMessages() external view returns (Message[] memory messages) {
        uint256 count = historyCount();
        messages = new Message[](count);
        for (uint256 i; i < count; ++i) {
            messages[i] = getMessage(i);
        }
    }

    /// @dev Strict UTF-8: rejects overlong sequences, surrogates, truncated sequences and > U+10FFFF.
    function _validateText(bytes calldata text) private pure {
        uint256 length = text.length;
        if (length == 0 || length > MAX_CHARACTERS * 4) revert InvalidMessageLength();
        uint256 characters = 0;
        uint256 i = 0;
        while (i < length) {
            uint8 lead = uint8(text[i]);
            uint256 width;
            if (lead < 0x80) {
                width = 1;
            } else if (lead >= 0xc2 && lead <= 0xdf) {
                width = 2;
            } else if (lead >= 0xe0 && lead <= 0xef) {
                width = 3;
            } else if (lead >= 0xf0 && lead <= 0xf4) {
                width = 4;
            } else {
                revert InvalidUtf8();
            }
            if (i + width > length) revert InvalidUtf8();
            for (uint256 j = 1; j < width; ++j) {
                uint8 continuation = uint8(text[i + j]);
                if (continuation < 0x80 || continuation > 0xbf) revert InvalidUtf8();
            }
            if (width >= 3) {
                uint8 second = uint8(text[i + 1]);
                if (
                    (lead == 0xe0 && second < 0xa0) || (lead == 0xed && second > 0x9f)
                        || (lead == 0xf0 && second < 0x90) || (lead == 0xf4 && second > 0x8f)
                ) revert InvalidUtf8();
            }
            i += width;
            if (++characters > MAX_CHARACTERS) revert InvalidMessageLength();
        }
    }
}
