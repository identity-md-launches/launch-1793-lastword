# Independent test additions

These tests supplement the accepted implementation's suite without changing source or configuration.

| File | Additional properties |
| --- | --- |
| `LastWord.LedgerInvariant.t.sol` | A fixed supply distributed across four actors, including the owner; arbitrary approvals, revoked approvals, insufficient balances, peer transfers, direct sink transfers, unsolicited board deposits, invalid posts, time changes, and repeated configuration attempts. Independent accounting checks each actor's balance and allowance, successful burns, pricing, immutable configuration, and all 50 retained messages after every handler call. |
| `LastWord.BoundaryProperties.t.sol` | Pricing over the full `uint256` domain, the exact escalation-overflow boundary, and reset at exactly 24 hours. Independent 512-bit inequalities check the smallest sufficient integer quote. UTF-8 properties mix character widths and place truncated or malformed sequences after valid prefixes, checking rollback and successful retry. |
| `LastWord.ExternalFailure.t.sol` | Token balance-read reverts and malformed return data before/after transfer, including rollback of a replaced 560-byte history entry; malformed decimal metadata leaves configuration available for retry; contract wallets batch two posts in one transaction with correct attribution, allowance use, cooldowns, and stale-bid rejection. |

The new invariant campaign uses 256 runs of 128 calls, with unexpected reverts treated as failures. Its initial state includes 50 free messages, a successful paid replacement, an approval failure, and direct transfers to both the sink and billboard. During randomized calls it never mints tokens, repairs balances, or reads contract state to choose an expected outcome. A deterministic sequence also exercises draining, refilling, revoking approval, rejecting a post, and retrying.

The full-width pricing properties use 2,048 examples each; the added UTF-8 properties use 1,024 each. Counts are set inline in the test files. Fixtures and dependencies are local, and the tests require no RPC, environment-variable cheatcodes, FFI, or network access.

Run the complete suite with the assignment's verifier seed:

```sh
forge build --offline
FOUNDRY_FUZZ_SEED=0x59eb5924b2d9cc04c00b02edf00ea12fe4f041bf402d0da9d792d6ce10dcade2 forge test --offline
```

The balance assertions distinguish unsolicited ERC-20 deposits from funds moved by posting: the billboard must retain only those direct deposits, and its burn total must exclude direct sink transfers. These local fixtures do not validate the future project's token address or behavior; that token is deliberately not configured at deployment.
