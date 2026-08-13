# verifier_ecdsa.sol — VerifierECDSA

`SPDX-License-Identifier: Apache-2.0`

The launch verifier: secp256k1 ECDSA with ERC-1271 fallback. Stateless, immutable, no
constructor arguments.

## Scheme id

```
keccak256("ECDSA-secp256k1-v1")
```

Once retired via `VerifierRegistry.retireScheme()`, this id can never be proposed again.

## Behavior

Delegates entirely to `ECDSALib.isValidSignatureNow`, which:

- rejects high-`s` signatures (EIP-2 malleability)
- rejects `v` outside {27, 28}
- rejects the zero address
- routes contract signers to ERC-1271 `isValidSignature` and checks for magic value
  `0x1626ba7e`

The EOA/contract branch is decided by `signer.code.length`.

## Known expiry date

This contract has one. secp256k1 falls to Shor's algorithm; only the timing is open.
When it happens:

1. Deploy the post-quantum verifier.
2. `registry.propose(newVerifier)`.
3. Wait 180 days. Both schemes stay live for 365 days after activation.
4. `registry.retireScheme(keccak256("ECDSA-secp256k1-v1"))`.

Nothing else in the system changes. That is the whole point of the indirection.

## Deployment

Deploy once. It takes no arguments and holds no state, so a single instance can serve
every contract in the stack — and any future BANKON deployment on the same chain.
