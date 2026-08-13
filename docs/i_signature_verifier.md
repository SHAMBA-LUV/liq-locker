# i_signature_verifier.sol — ISignatureVerifier

`SPDX-License-Identifier: Apache-2.0`

The only place this system knows what a signature is.

## Contract

```solidity
function verify(address signer, bytes32 digest, bytes calldata signature)
    external view returns (bool valid);

function schemeId() external pure returns (bytes32 id);
```

## Implementation requirements

**Stateless and view-only.** A verifier that writes storage is a verifier that can be
griefed — an attacker fills its storage or triggers a revert path and takes down every
signature check in the system.

**Never revert on a bad signature.** Return `false`. Callers treat a revert as a failed
verification, but a reverting verifier makes debugging and gas estimation miserable.

**`schemeId()` must be unique and stable.** It is the key in the registry's permanent
retirement ban list. Reusing an id across incompatible implementations means retiring one
retires the other.

## Migration path

Today: `VerifierECDSA` (secp256k1 + ERC-1271).

Later: ML-DSA (FIPS 204), SLH-DSA (FIPS 205), or a native precompile. Implement this
interface, deploy, propose on the registry, wait 180 days, activate. No asset moves and
no other contract changes.

## Why an interface rather than a library

A library is linked at compile time and frozen in the bytecode. An interface is resolved
at call time through an address. Only the second one can be swapped after deployment,
which is the entire requirement.
