# Implementation checks and independent-review handoff

This document records the implementation-stage analysis and tests. It is not an independent audit or launch approval. A separate contributor must review the accepted source and the later generated manifest before release. No deployment, source publication, admission, signed-artifact verification, or live token validation was performed in this assignment.

## Authority and trust

- `initialOwner` must be the approved creator, `0xb77161bbaf98470c6c5101899d30df413f9a019d`. A factory deployment test confirms that neither factory nor transaction origin acquires ownership. Owner storage is immutable.
- The only owner action is one successful `setToken`. It cannot delete messages, change limits, reset pricing, withdraw funds, pause, upgrade, or transfer ownership. Loss of the creator's key before connection leaves the billboard free indefinitely.
- Token code and metadata are checked at connection, which deliberately occurs after deployment. These checks establish neither token identity nor honest behavior. The creator must select the real project token. A malicious/upgraded/rebasing/paused/blocklisted token can compromise liveness or lie about transfers; no wrapper can establish truthful balances for a hostile token.
- Ordinary transfers to the prescribed sink must credit the exact amount, and decimals must remain stable. Short credits, extra credits, missing transfers, decreasing sink balances, false returns, and reverting transfers are tested as failures. Optional empty return data is supported.
- Users choose and approve an exact token amount. LastWord has no function allowing anyone to choose a different debtor, arbitrary recipient, or arbitrary external call target. Every successful transfer goes from the calling author directly to the constant sink.

## State integrity

The state-changing functions share OpenZeppelin's reentrancy guard. Validation and message/accounting effects precede transfer execution. Failure of the token call or exact sink-balance check reverts all effects. Both caught and propagated callback attempts are tested, including entry into the token setter. View calls during a token callback can observe in-progress state; no application action relies on callbacks or external views of that transient state.

The minimum grows from the actual preceding burn, rounded upward in base units. Arithmetic splits the ten-percent increment to avoid multiplying a large burn by eleven. An unrepresentable next minimum produces a specific error until the 24-hour reset. Totals and counters use Solidity checked arithmetic. No timestamp or block value is used for randomness. Timestamp thresholds deliberately implement the requested cooldown and idle reset; clients should use chain time.

History writes use a fixed 50-slot ring. Reads expose chronological order with explicit bounds checks. The aggregate burn total is independent of retention. UTF-8 validation bounds accepted text to 560 bytes and 140 scalar values and rejects overlong, surrogate, truncated, and out-of-range encodings. Loops are bounded by these constants or the 50-message history.

No payable function, fallback, receive function, transfer-to-owner flow, proxy, external library link, `delegatecall`, `callcode`, or `selfdestruct` exists in the application. Forced ETH or unsolicited token transfers can still strand funds at any contract address. There is deliberately no recovery authority.

## Executed checks

The local suite uses Solidity 0.8.26 with the committed compiler settings and the assignment's fuzz seed. It covers:

- Explicit owner/factory separation, invalid owner, one-time configuration, unauthorized access, zero/no-code/missing-metadata tokens, and token scales from 0 through 74 decimals.
- Free per-address cooldown including timestamp zero, exact 600-second boundary, different wallets, owner parity, duplicates, and the switch from free to paid while a cooldown is active.
- First-paid floor, multiple same-block paid replacements, overpayment, upward rounding, stale bids, exact 24-hour reset, clock restart, unrelated sink transfers, missing allowance, insufficient balance, and overflow/reset recovery.
- Atomic rollback for false/reverting/no-op/fee/malformed/excess-credit tokens and reentrancy. Failure is also tested when replacing a slot in a full history buffer.
- 140 ASCII characters and 140 four-byte emoji, mixed scripts, combining characters, valid scalar boundaries, invalid UTF-8 categories, oversized messages, and fuzzed valid Unicode scalars.
- More than three complete ring-buffer cycles, oldest/newest ordering, long-to-short string replacement, and cumulative burns surviving eviction.
- A stateful model that interleaves token configuration, free posts, paid posts, invalid bids, unauthorized calls, and forward time. It checks all retained messages, current message, pricing, cooldowns, authority, token conservation, and zero normal-path custody/fees after each step.
- Runtime size and an opcode scan matching the supplied deployment floor's forbidden-opcode policy.

The configured invariant campaign performs 128 runs × 100 handler calls. Foundry's default test parallelism is supported: fixtures are isolated, no fork/RPC/clock delay is used, and tests neither read nor set environment variables.

Forge's remaining source lint warnings concern intentional timestamp comparisons and rejection branches inside bounded validation/history loops. These are required behavior, not unchecked external calls. No Slither or Mythril result is claimed. The supplied protected tests depend on the later service's deployment variables and owner harness; they are inputs for review, not copied into this standalone test suite.

## Release handoff

The independent review should check this source and its ABI alongside the manifest's sole application and exact owner argument. The manifest step owns `launch.json`; this source contribution does not generate it. Policy enforcement, signed artifact linkage, deployment simulation, and live deployment records belong to the launch services.

Before token connection, the creator must verify the project's actual mainnet token address and suitability. Before frontend publication, the website publisher must use the service-confirmed application address, hide token features while unconfigured, handle stale quotes and approvals, and render untrusted text safely. None of these later outcomes is represented as already complete.
