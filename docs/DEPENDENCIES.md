# Vendored dependencies

These dependencies are included as ordinary files so an offline verifier can build without fetching packages. No Git submodules or package-manager install step are used.

| Directory | Upstream revision | Included content | License |
| --- | --- | --- | --- |
| `lib/openzeppelin-contracts/` | [OpenZeppelin Contracts v5.1.0](https://github.com/OpenZeppelin/openzeppelin-contracts/tree/v5.1.0) | Unmodified source dependency closure of `SafeERC20`, `IERC20Metadata`, and `ReentrancyGuard`, plus license. | MIT |
| `lib/forge-std/` | [forge-std v1.9.7](https://github.com/foundry-rs/forge-std/tree/v1.9.7) | Unmodified `src/` and both upstream license files. Test dependency only. | Apache-2.0 OR MIT |

Source archives used:

- `https://codeload.github.com/OpenZeppelin/openzeppelin-contracts/tar.gz/refs/tags/v5.1.0`
- `https://codeload.github.com/foundry-rs/forge-std/tar.gz/refs/tags/v1.9.7`

LastWord uses only `safeTransferFrom` from SafeERC20 and the storage-based reentrancy guard. Library calls are internal/inlined; the application has no externally linked library addresses. Repository-local remappings are in `remappings.txt`.
