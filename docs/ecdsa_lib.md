# ecdsa_lib.sol — ECDSALib

`SPDX-License-Identifier: Apache-2.0`

Signature recovery enforcing EIP-2 low-`s`, canonical `v`, and non-zero signer, plus an
ERC-1271 branch for contract signers.

## Why not raw ecrecover

Two footguns:

1. **Malleability.** For any valid `(r, s, v)`, the pair `(r, n - s, v')` is also valid
   and recovers the same address. If you use the signature bytes as a uniqueness key —
   a replay-protection set, a nonce map — an attacker flips `s` and passes the same
   authorization twice. EIP-2 fixed this at the consensus layer for transactions but
   `ecrecover` still accepts high-`s`.

2. **Silent failure.** `ecrecover` returns `address(0)` on failure rather than reverting.
   Any code comparing the result against an uninitialized storage address passes.

## The bound

```
HALF_ORDER = secp256k1n / 2
           = 0x7FFF...5D576E7357A4501DDFE92F46681B20A0
```

Yellow Paper Appendix F. Any `s` above this is rejected.

## Two entry points

| Function | Behavior |
|---|---|
| `recover(hash, sig)` | strict; reverts with a typed error on any irregularity |
| `isValidSignatureNow(signer, hash, sig)` | non-reverting; returns `false`; handles EOA and ERC-1271 |

`isValidSignatureNow` is what `VerifierECDSA` uses, because the verifier interface
contract says return `false` rather than revert.

## ERC-1271 branch

For contract signers (a Safe, a modular smart account, the multisig itself), staticcalls
`isValidSignature(bytes32,bytes)` and requires the return to equal `0x1626ba7e`. The
staticcall means a malicious signer contract cannot mutate state during verification.

## Before mainnet

This is hand-written cryptographic code. **Differentially fuzz it against a reference
implementation** (OpenZeppelin's `ECDSA`) over random `(hash, v, r, s)` tuples — they must
agree on every input, including malformed ones. This is the single highest-value test in
the repository.
