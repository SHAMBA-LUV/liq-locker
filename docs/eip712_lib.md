# eip712_lib.sol — EIP712Lib

`SPDX-License-Identifier: Apache-2.0`

Domain separator with fork protection. Inherited by `MultisigTimelockVault` and
`SuccessionModule`.

## What the separator buys

Binding `name`, `version`, `chainId`, and `verifyingContract` defeats two replay classes
for free:

- **Cross-chain** — a heartbeat signed for mainnet cannot be replayed on an L2 or a
  fork, because `chainId` is inside the hash.
- **Cross-contract** — a signature for the succession module cannot be replayed against
  the multisig, because `verifyingContract` differs.

Cross-*time* replay is not covered here; that is the caller's nonce (`vaultNonce` in the
multisig, `nonces[incumbent]` in the succession module).

## Fork protection

The separator is computed once and cached in immutables. If `block.chainid` changes after
deployment — a chain fork — the cache is invalidated and the separator rebuilt, so
signatures do not replay across the fork.

The check is `address(this) == _cachedThis && block.chainid == _cachedChainId`. The
address comparison also guards against use behind a proxy, where `address(this)` would
differ from the deployed logic address.

## Cost

Cached path: two immutable reads and a comparison. Rebuilt path: one `keccak256` over
five words. The cache means the common case pays essentially nothing.

## Typed data

```solidity
_hashTypedData(structHash) = keccak256(0x1901 ‖ domainSeparator ‖ structHash)
```

The `0x1901` prefix is the EIP-191 version byte for structured data. Getting this wrong
produces signatures that verify in your tests and fail against every wallet.

## Typehashes live in the consuming contract

Deliberate. The struct definition belongs with the logic that uses it, and keeping the
typehash next to the `abi.encode` that fills it makes field-order mistakes visible in one
place.
