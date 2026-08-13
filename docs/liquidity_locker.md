# liquidity_locker.sol

Ownerless, beneficiary-bound, extend-only ERC-20 timelocks.

`Apache-2.0` · 3,964 bytes runtime · no dependencies

---

## What it is

A registry of locks. Each lock names a token, an amount, a beneficiary, and a maturity.
Before maturity nobody can move the tokens. At maturity only the beneficiary can. There
is no owner, no pause, no upgrade path, and no setter of any kind.

## Interface

| Function | Who | Notes |
|---|---|---|
| `lock(token, amount, unlock_at, beneficiary)` | anyone | `beneficiary = address(0)` means self. Returns the global id |
| `extend(id, new_unlock_at)` | beneficiary | forward only, capped at `MAX_LOCK_DURATION` |
| `assign(id, to)` | beneficiary | moves custody, never maturity |
| `withdraw(id)` | beneficiary | after maturity |
| `withdraw_to(id, to)` | beneficiary | after maturity, to a nominated address |
| `sweep_surplus(token)` | **anyone** | pays only to `SURPLUS_SINK` |
| `lock_at(id)` | view | `(token, beneficiary, amount, unlock_at, withdrawn)` |
| `is_locked(id)` | view | false once matured or withdrawn |
| `locks_of(user)` | view | O(n), `eth_call` only |
| `surplus(token)` | view | balance no lock claims |
| `total_locked(token)` | view | sum of live locks |

## Constructor

```solidity
constructor(address surplus_sink_)
```

One argument, immutable, unrecoverable if wrong. See `usage.md` §3.

## The three decisions worth understanding

**Ids are global, not per-user.** A lock's identity must survive `assign`. If ids were
indices into a per-user array, reassigning would renumber the lock and break every event,
bookmark, and external reference to it.

**`_index_of` is not authoritative.** `assign` appends to the new beneficiary and never
removes from the old, because removal from a dynamic array is either O(n) or reorders ids.
`locks_of` filters against `_locks`, which is the real record. Never read `_index_of`
as truth. Pinned by `test_LocksOfFiltersStaleIndexEntries`.

**Credits are measured deltas.** `lock` reads `balanceOf` before and after the transfer and
credits the difference. A fee-on-transfer token would otherwise push `total_locked` above
the real balance, and the last withdrawer would eat the shortfall.
`test_TwoFeeTokenLockersBothExit` is the test that fails without this.

## Why `sweep_surplus` is not an admin key

It is callable by anyone and the caller chooses nothing — not the destination, not the
amount. `SURPLUS_SINK` is immutable and the amount is `balance − total_locked`, computed
on the spot. A locked token is excluded arithmetically, so the function cannot reach a
live lock even if every address on the chain calls it at once.

This is BANKON's `bankon_custody.redeem_*` pattern: a permissionless sweep is safe
precisely because its destination can never change. It replaces the owner-only `rescue`
that the inherited design needed, which is what makes removing the owner possible at all.

## Bounds

| Constant | Value | Adversary it defends against |
|---|---|---|
| `MAX_LOCK_DURATION` | 3650 days | a mistyped unix timestamp locking liquidity until the year 50,000 |

`unlock_at` is `uint48`. `uint32` overflows in 2106, which is inside the design horizon.

## Known limits

- Rebasing-down tokens under-deliver. Do not lock them. UNI-V2 pairs are not rebasing.
- A bug here is permanent — no pause, no owner, no upgrade.
- Beneficiary key loss at maturity is unrecoverable. Use `assign` *before* it becomes
  urgent, ideally to a succession-governed contract.

## Tests

`test/liquidity_locker.t.sol` — 25 tests. Map in `technical.md` §8.
