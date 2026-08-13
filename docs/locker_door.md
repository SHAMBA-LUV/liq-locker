# locker_door.sol

`liquidity_locker` plus EIP-712 consent, gasless relay, and the φ fee.

`Apache-2.0` · 7,728 bytes runtime · inherits `liquidity_locker`

---

## The lock and the door

The **lock** is the timelock, inherited unchanged. The **door** is the signature: three
verbs, each authorised by the beneficiary rather than by whoever sends the transaction.

| Verb | Function | Who signs | Who may submit | Fee |
|---|---|---|---|---|
| lock your own | `lock_your_own` | — | you | φ |
| close the door for another | `lock_with_consent` | the beneficiary | the funder | φ |
| open the door | `open_door` | the beneficiary | **anyone** | none |
| extend | `extend_by_sig` | the beneficiary | anyone | none |

The signature is the key, not the sender.

## Why `bytes` and not `(v, r, s)`

This is the substantive change from `LUVLockerDoor`, and there are two independent
reasons for it.

**Post-quantum signatures do not fit in 65 bytes.** ML-DSA-44 is 2,420 bytes; SLH-DSA-128s
is 7,856. A `(v, r, s)` parameter list cannot express them, so a door built that way can
never migrate schemes at all. For a primitive whose purpose is a lock measured in years,
that is a designed-in expiry date: on the day secp256k1 falls, the door still works
perfectly and holds the liquidity hostage forever.

**Contracts cannot produce a secp256k1 signature.** ERC-1271 exists for multisigs, smart
accounts, and EIP-7702 delegated EOAs, and it takes `bytes`. A `(v, r, s)` door silently
excludes every contract wallet from being a beneficiary — including `bankon.eth` itself,
which is an EIP-7702 delegated account, and which is exactly the party that would hold
the most important lock.

`test_Erc1271ContractSignerCanOwnAndOpenALock` pins the second.

## The verifier

```solidity
ISignatureVerifier public immutable VERIFIER;
```

Every signature check in the contract routes through one internal function, `_check`,
which calls `VERIFIER.verify(signer, digest, signature)`. That is one line to audit and
one line that changes when the scheme does.

Two deploy-time choices, and they are not equivalent:

- **`VerifierECDSA`** — bare secp256k1 with ERC-1271 fallback. Correct today, permanently
  fixed.
- **bankon-vault's `VerifierRegistry`** — the scheme can migrate behind a 180-day timelock
  without moving a locked token.

The verifier address is immutable *per door*, so all the risk and all the optionality sit
in this one constructor argument. **The verifier is trusted absolutely**: a hostile one
forges consent and opens any door in that deployment. It cannot touch a separately
deployed `liquidity_locker`, which has no verifier at all.

## The φ fee

```
fee(wei) = LOCK_GAS_UNITS × tx.gasprice × PHI_WAD / 1e18
PHI_WAD  = 1.618033988749894848 × 1e18
```

The service costs φ times the gas bill of the locking transaction, priced at that
transaction's own gas price. Split 61.8% / 38.2% — the golden section itself — between
`OVERLORD` and `OVERSEER`, both **immutable**. `LUVLockerDoor` had `setOverseer`; a
mutable payee is an admin key wearing a different hat, and this house does not keep those.

BANKON caps fees in the contract rather than in config (`cp2048_constants.MAX_FEE_NUM = 3`:
never more than three times the cost of the call it prices). φ < 3, so the ceiling holds by
construction. `testFuzz_PhiFeeNeverExceedsCap` asserts it across the whole gas-price range,
so a future edit to `PHI_WAD` cannot quietly break it.

**Stated plainly:** `tx.gasprice` is chosen by the caller, so the fee is adjustable
downward by anyone willing to transact cheaply, and is zero at a gas price of zero. That
is the design — the fee is proportional to the cost of the service at the moment it is
used — not a leak. There is no floor.

Fees are **pulled**, never pushed: `collect_fees` is the only payout path, so a payee that
reverts on receive cannot brick locking for everyone else
(`test_RevertingPayeeCannotBrickTheDoor`).

## Exits are never charged and never gated

`open_door` is not payable. `withdraw` on the base contract needs no fee, no signature,
and no door function to work. If every door function became unusable tomorrow, every
beneficiary could still get out. That is the property that keeps the fee non-coercive,
and `test_BaseWithdrawIsStillFreeAndUngated` is what pins it.

## Replay protection

One nonce per signer, shared across all three verbs — so a signature minted for one intent
can never be replayed as another. The EIP-712 domain separator binds `chainid` and
`verifyingContract`, and `EIP712Lib` rebuilds it if `chainid` changes, so signatures do
not replay across chains or across a fork. `lock_with_consent`'s digest also commits to
the **funder**, so consent given to one party is not consent given to any party.

Deadlines are absolute timestamps and are checked before anything else.

## Tests

`test/locker_door.t.sol` — 19 tests.
