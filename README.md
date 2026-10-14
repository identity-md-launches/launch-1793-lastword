# LastWord

LastWord is one public billboard on Ethereum mainnet. Anyone can replace its message. Posting is free until the creator permanently connects the project's ERC-20, then every replacement transfers the author's approved tokens directly to `0x000000000000000000000000000000000000dEaD`.

This repository delivers the application contract, Foundry tests, vendored dependencies, ABI export, and integration/deployment documentation for the contract implementation stage. Independent review, `launch.json`, source publication, deployment, and the website/IPFS release are subsequent workflow responsibilities. No live deployment address is asserted here.

## Build and check

Run from the repository root with Foundry and Solidity **0.8.26** installed:

```sh
forge build
FOUNDRY_FUZZ_SEED=0x59eb5924b2d9cc04c00b02edf00ea12fe4f041bf402d0da9d792d6ce10dcade2 forge test
forge fmt --check
```

All Solidity dependencies and their licenses are ordinary files under `lib/`; no dependency download, submodule, RPC, wallet, environment-file configuration, FFI, or filesystem cheatcode permission is required. Tests use local fixtures and explicit constructor arguments. The seed above is the assignment's verification seed; tests do not read or mutate environment variables.

`foundry.toml` pins Solidity 0.8.26, Cancun, optimizer enabled with 200 runs, and `bytecode_hash = "none"`. There are 1,024 runs per fuzz test and 128 stateful invariant runs of depth 100, with unexpected handler reverts treated as failures.

The machine-readable ABI is [docs/abi/LastWord.json](docs/abi/LastWord.json); [docs/ABI.md](docs/ABI.md) explains the interface. Regenerate after changing the interface:

```sh
forge inspect src/LastWord.sol:LastWord abi --json > docs/abi/LastWord.json
```

## Behavior and assumptions

| Rule | Implementation |
| --- | --- |
| Message | 1–140 valid UTF-8 Unicode code points; empty text is rejected. |
| Free mode | `token() == address(0)`, `minimumBurn() == 0`; call `setMessage(text, 0)`. |
| Free cooldown | Each caller address may post once every 600 seconds, inclusive at the boundary. The first post needs no waiting. |
| Token connection | Immutable owner calls `setToken(address)` once. Successful connection immediately and permanently ends free mode. |
| First paid post | At least 1,000 whole tokens, scaled using the connected token's `decimals()`. Free posts do not affect this floor. |
| Subsequent paid posts | At least `ceil(previousActualBurn * 11 / 10)` base units. Voluntary overpayment raises the next minimum. There is no paid-mode cooldown. |
| Inactivity reset | At or after 86,400 seconds since the last successful post, the minimum is 1,000 tokens. No reset transaction is necessary. |
| Burn | `transferFrom(msg.sender, BURN_ADDRESS, burnAmount)`, after the author approves LastWord. The exact amount must arrive. |
| History | Last 50 successful messages, oldest first; both free and paid posts count. Events retain the historical record beyond that window. |
| Accounting | `totalBurned()` is the lifetime sum of successful paid posts, even after history rolls over. |
| Administration | The owner only connects the token once. No ownership transfer, pause, upgrade, moderation, fee, withdrawal, or price-setting functions. |

The fixed constants are `MAX_CHARACTERS = 140`, `HISTORY_LIMIT = 50`, `FREE_COOLDOWN = 600`, `RESET_INTERVAL = 86400`, `BASE_TOKENS = 1000`, and `MAX_TOKEN_DECIMALS = 74`. The maximum decimals value is the largest for which 1,000 whole tokens fit in a `uint256`.

“Characters” means Unicode code points, not displayed grapheme clusters. Combining marks and emoji sequences may contain several code points. Text is preserved verbatim with no normalization or moderation; repeated identical text is permitted. All valid Unicode scalar values, including controls, are accepted. Clients must render it as untrusted text. Each wallet address, including a smart-contract wallet, has its own free cooldown; it is not a per-person or Sybil-resistance mechanism.

Amounts are raw token base units. For 18 decimals, the floor is `1000 * 10**18`; for six decimals it is `1000 * 10**6`. `burnAmount` is an exact chosen spend, not a cap from which the contract automatically selects a smaller amount. A quote that becomes too low reverts; a transaction whose quote becomes higher than the floor still burns its chosen amount. Use integer arithmetic and refresh the quote before posting.

The sink transfer does **not** reduce ERC-20 `totalSupply()`. `totalBurned()` means tokens sent to the prescribed sink through LastWord, excluding unrelated direct transfers. Failed posts spend no tokens and change no message, timestamp, history, cooldown, or totals. Normal operation never routes tokens or ETH through LastWord. Nonpayable methods and the absence of a receive/fallback function reject ordinary ETH sends. Forced ETH and unsolicited ERC-20 transfers cannot be prevented and have no recovery mechanism.

## Deployment parameters

| Parameter | Required value |
| --- | --- |
| Chain | Ethereum mainnet, chain ID `1` |
| Application | `LastWord` from `src/LastWord.sol` |
| Constructor | `constructor(address initialOwner)`; nonpayable |
| `initialOwner` | `0xb77161bbaf98470c6c5101899d30df413f9a019d` (the creator) |
| Deployment ETH | `0` |
| Constructor dependencies | None; no external calls or code-presence requirements |
| Initial token | Intentionally unconfigured; the project token is launched later |
| Initial message | Empty sentinel with zero author/burn/timestamp and `messageCount() == 0` |

The factory and transaction origin acquire no rights. The owner is immutable and must be supplied explicitly. The manifest assignment should deploy only `LastWord` with the creator address above (or the launch's `$owner` resolving to that same creator); none of the contracts under `test/` are applications. There is no token, distributor, pool, proxy, linked external library, payable constructor, or initialization transaction in this deployment.

The build's runtime is 5,306 bytes and creation bytecode is 5,481 bytes before the static constructor argument. Both are below the deployment limits. The application opcode test rejects `DELEGATECALL`, `CALLCODE`, and `SELFDESTRUCT`.

## After launch

1. **Deployment service:** independently review the accepted source and generated manifest, publish/attest/admit the artifacts, deploy LastWord with the exact creator address, and provide confirmed chain/address/ABI information to the frontend. Source publication and deployment verification belong to the service. No worker broadcast or signing script is needed.
2. **Creator:** when the project's own token has launched on Keel on Ethereum mainnet, obtain its actual deployed address from that project's verified deployment record. Check its identity, `decimals()`, transfer behavior, and any token-admin powers. From the creator wallet, call **`LastWord.setToken(actualProjectTokenAddress)`**. This is the sole deferred setting; it emits `TokenSet(token)`. No address is guessed or embedded here.
3. **Creator:** confirm `token()`, `tokenDecimals()`, `baseMinimumBurn()` and the event after the transaction. Connection cannot be undone or corrected. Before calling, verify that ordinary `transferFrom` can transfer exactly the selected amount to the sink, without a fee, rebase, blacklist restriction, or burn-on-send behavior. Decimal metadata must stay consistent after connection.
4. **Website publisher:** use only the service-confirmed mainnet address. While `token() == address(0)`, hide token controls and show free posting with `nextFreePostAt(wallet)`. Once connected, show an exact-amount **Approve → Post** flow, the current minimum, history, and cumulative burn. Read `tokenDecimals()` to format amounts. Render messages as plain text, never HTML. Website implementation and IPFS publication follow the deployment handoff.

The token setter rejects a zero address, an address without code, missing/reverting decimal metadata, decimals above 74, unauthorized calls, and any second successful setting. Failed configuration leaves free mode and the token slot intact. ERC-20 transfers may return `true` or no return data; failures and sink-balance mismatches revert. Fee-on-transfer and rebasing tokens are unsupported. A malicious token can lie about balances or change behavior, so token selection remains a creator trust assumption. If the connected token later becomes unusable, paid posting can stop permanently; LastWord deliberately has no administrative bypass.

See [docs/SECURITY.md](docs/SECURITY.md) for the local checks, threat assumptions, and independent-review handoff, and [docs/DEPENDENCIES.md](docs/DEPENDENCIES.md) for dependency provenance.
