# LastWord ABI and client handoff

The compiler-generated JSON ABI is [abi/LastWord.json](abi/LastWord.json). All calls use the service-confirmed LastWord address on chain ID 1. Amounts and timestamps are `uint256`; use arbitrary-precision integers in clients. No method accepts ETH.

## Writes

| Signature | Caller and behavior |
| --- | --- |
| `setMessage(string text, uint256 burnAmount)` | Anyone; posts as `msg.sender`. Text must contain 1–140 valid UTF-8 code points. Use amount zero in free mode, or the exact approved spend at/above `minimumBurn()` in paid mode. |
| `setToken(address newToken)` | Immutable owner only, once successfully. Reads decimals, sets the token and 1,000-token floor, and permanently switches to paid mode. |

Approval is an ERC-20 call to the address returned by `token()`: `approve(lastWordAddress, burnAmount)`. LastWord always debits its own caller, never an author supplied in calldata. Wait for successful approval, re-read the minimum, and submit the chosen exact amount. If a token requires clearing an old allowance before replacing it, the client must handle that ERC-20 approval behavior. Avoid unlimited approvals.

The minimum is evaluated when the post executes. Another author can raise it before inclusion; `BurnTooSmall(minimum, supplied)` leaves the old message and tokens intact. A 24-hour reset can instead lower it; the supplied amount is still spent in full. Clients should show this exact spend and require a fresh user decision before increasing it. Successful posting cannot guarantee how long a message remains current.

## Reads

| Signature | Return / interpretation |
| --- | --- |
| `owner()` | The immutable creator wallet. |
| `token()` | Connected ERC-20 address; zero means free mode. |
| `tokenDecimals()` | Decimal scale cached at connection. In free mode its default zero is not usable token metadata; check `token()` first. |
| `baseMinimumBurn()` | 1,000 whole tokens in base units after connection; zero beforehand. |
| `minimumBurn()` | Required burn now, including inactivity reset; zero in free mode. |
| `currentMessage()` | A `Message` tuple. Before any post: zero author, empty text, zero burn/timestamp. |
| `messageCount()` | Lifetime count of successful free and paid posts. |
| `historyCount()` | Retained count, from zero to 50. |
| `getMessage(uint256 index)` | Retained message at chronological index; zero is oldest. Invalid indices revert. |
| `getRecentMessages()` | All retained messages in chronological order, oldest first, in one call. Reverse for a newest-first UI. |
| `totalBurned()` | Lifetime base units transferred to the sink by successful posts, including evicted messages. |
| `nextFreePostAt(address author)` | Earliest timestamp for that caller's next free post; zero before their first post. Ignore in paid mode. |

`Message` tuples have fields in this order:

```solidity
struct Message {
    address author;
    string text;
    uint256 burned;
    uint256 timestamp;
}
```

Ring-buffer indices change as new posts arrive. Read at a fixed block tag if combining multiple RPC calls, or use `getRecentMessages()` for one coherent history read. `messageCount()` is the reliable empty-state indicator. The age of the current message is the current chain timestamp minus `currentMessage().timestamp`; the minimum uses chain time, not the browser clock. The reset preserves the current message and history until a new post succeeds.

The public constants also appear in the ABI: `MAX_CHARACTERS()`, `HISTORY_LIMIT()`, `FREE_COOLDOWN()`, `RESET_INTERVAL()`, `BASE_TOKENS()`, `MAX_TOKEN_DECIMALS()`, and `BURN_ADDRESS()`.

## Events

```solidity
event TokenSet(address indexed token);
event MessageSet(address indexed author, string text, uint256 burned, uint256 timestamp);
```

Each successful replacement emits exactly one `MessageSet`, including free posts (`burned == 0`). `timestamp` is the block timestamp of that replacement. The event is emitted after a paid transfer is verified. `TokenSet` occurs only on successful one-time configuration. Filter logs by the deployed contract address and handle chain reorganizations normally. Historical messages older than the retained 50 can be reconstructed from confirmed logs.

## Failure handling

| Error | Meaning / client response |
| --- | --- |
| `InvalidMessageLength()` | Empty text or more than 140 code points (or more than 560 bytes). |
| `InvalidUtf8()` | Invalid, overlong, surrogate, out-of-range, or truncated UTF-8 sequence. |
| `FreePostRequiresZeroBurn()` | Nonzero burn specified before connection; refresh mode. |
| `CooldownActive(uint256 availableAt)` | Wait until this chain timestamp in free mode. |
| `BurnTooSmall(uint256 minimum, uint256 supplied)` | Refresh the quote, balance, and approval; let the author choose a new spend. |
| `BurnAmountMismatch()` | The token's sink balance did not increase by the exact requested amount; the whole post reverted. |
| `MinimumBurnOverflow()` | The next 10% increase exceeds `uint256`; wait until 24 hours after the current message for the reset. |
| `Unauthorized()` | `setToken` caller is not the creator. |
| `TokenAlreadySet()` | The token slot is permanently occupied. |
| `InvalidToken()` | Zero token address or no deployed code. |
| `InvalidTokenDecimals()` | Decimal metadata is unavailable or unsupported. |
| `HistoryIndexOutOfBounds()` | Index is outside the retained history. |
| `InvalidOwner()` | Constructor owner is zero; deployment arguments are invalid. |
| `ReentrancyGuardReentrantCall()` | A token attempted a nested state-changing call. |
| `SafeERC20FailedOperation(address token)` | ERC-20 returned failure or invalid success data. |

Underlying ERC-20 balance, allowance, pause, or blacklist errors can also bubble up. All these failures revert atomically. Checked arithmetic prevents counters and totals from wrapping. With a conventional ERC-20 and an inaccessible sink, cumulative burns cannot exceed the token's representable balance. The extreme next-minimum overflow case is explicitly tested.

For UTF-8-aware frontend validation, count Unicode code points rather than JavaScript UTF-16 code units (for example `Array.from(text).length` for a well-formed string). Do not interpret control sequences, markup, or URLs from message text as executable content. The contract provides no moderation.
