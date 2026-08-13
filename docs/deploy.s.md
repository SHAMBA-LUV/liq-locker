# deploy.s.sol

Deploys the free primitive, a launch verifier, and the optional door.

## Environment

| Variable | Required | Meaning |
|---|---|---|
| `SURPLUS_SINK` | yes | where swept tokens go, forever |
| `OVERLORD` | yes | 61.8% of every φ fee, immutable |
| `OVERSEER` | yes | 38.2%, immutable |
| `VERIFIER_ADDR` | no | omit to deploy a permanent-ECDSA verifier |

```sh
make fork      # dry run against mainnet state
make deploy    # --broadcast --verify --slow
```

## What it deploys, and why in that order

1. **`liquidity_locker`** — the free path. No fee, no signatures, no privileged address.
   Deployed first and independently so it survives anything that goes wrong with the door.
2. **`VerifierECDSA`** — only if `VERIFIER_ADDR` is unset. The script logs a warning when
   it does this, because the consequence is permanent.
3. **`locker_door`** — the serviced path.

## The choice this script makes you make

`VERIFIER_ADDR` unset gives a door whose signature scheme is secp256k1 **forever**. Set it
to bankon-vault's `VerifierRegistry` and the scheme can migrate behind that registry's
180-day timelock without moving a locked token.

Neither is wrong. Both are permanent. See `technical.md` §2 and `usage.md` §3.

## The two contracts do not share locks

A lock created through the door lives in the door's storage. This is intended and the
script says so on completion — the free primitive is not a fallback entrance to the door,
it is a separate deployment with its own lock registry.

## Nothing in this script is reversible

There are no setters in either contract. A mistake is fixed by deploying again, not by
correcting it. Rehearse on a testnet, including a sweep to `SURPLUS_SINK` — that sweep is
the only way to confirm the one argument you cannot fix.
