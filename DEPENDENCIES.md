# Vendored dependencies

All dependencies are checked-in source files, without submodules, nested Git directories, installation hooks, or `node_modules`. Versions and downloaded archive SHA-256 hashes are in [DEPENDENCIES.json](DEPENDENCIES.json). The archive hashes identify the original download; only the source/license portions listed below are retained.

| Dependency | Revision | Included files | License |
| --- | --- | --- | --- |
| [Uniswap v4-core](https://github.com/Uniswap/v4-core/tree/46c6834698c48bc4a463a86d8420f4eb1d7f3b75) | `46c6834698c48bc4a463a86d8420f4eb1d7f3b75` | `src/`, `LICENSE` | Per-file SPDX, including BUSL-1.1 and MIT; see `lib/v4-core/LICENSE`. |
| [OpenZeppelin Contracts 5.2.0](https://github.com/OpenZeppelin/openzeppelin-contracts/tree/acd4ff74de833399287ed6b31b4debf6b2b35527) | `acd4ff74de833399287ed6b31b4debf6b2b35527` | `contracts/`, `LICENSE` | MIT. |
| [forge-std 1.9.7](https://github.com/foundry-rs/forge-std/tree/77041d2ce690e692d6e03cc812b57d1ddaa4d505) | `77041d2ce690e692d6e03cc812b57d1ddaa4d505` | `src/`, both license files | MIT / Apache-2.0. |
| [Solmate](https://github.com/transmissions11/solmate/tree/4b47a19038b798b4a33d9749d25e570443520647) | `4b47a19038b798b4a33d9749d25e570443520647` | `Owned.sol`, `ERC20.sol`, `MockERC20.sol`, `LICENSE` | AGPL-3.0 base; individual included Solidity files have their own SPDX declarations. |

Solmate is the revision pinned by the selected v4-core repository. Its `Owned` contract is used by the **test PoolManager**, not by Crown or CrownHook. The launch contracts never inherit ownership. No downloaded repository configuration or documentation is executed.

The production token imports only OpenZeppelin's standard ERC-20 implementation. The hook imports OpenZeppelin's reentrancy guard and Uniswap interfaces, types, and internal libraries. The complete PoolManager implementation is compiled for local integration tests; it is not a third contract for the launch to deploy. No production bytecode requires external library linking.
