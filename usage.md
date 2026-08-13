# usage.md — liq-locker

Build, deploy, operate. Written for the person doing it at 2am, not for the person who
wrote it.

---

## 1. Build and test

```sh
make test      # 44 tests, 2 suites
make sizes     # all contracts must be under 24,576 bytes
make gas
make audit     # the regression suite — never skip before a deployment
```

`lib/forge-std` is a symlink. If it is dangling, point it at any forge-std checkout:

```sh
ln -sfn /path/to/forge-std lib/forge-std
```

Nothing else is required. `src/` imports nothing from outside its own directory.

---

## 2. What each contract is for

| You want to | Use |
|---|---|
| Lock LP and prove it, cheapest and simplest | `liquidity_locker`, free |
| Lock on someone's behalf, with their consent | `locker_door.lock_with_consent` |
| Let a beneficiary exit without holding gas | `locker_door.open_door`, any relayer |
| Run it as a service and earn the φ fee | `locker_door.lock_your_own` |

If you are locking your own treasury's LP and nothing else, deploy only
`liquidity_locker`. The door is for offering this to other people.

---

## 3. Pre-deploy decisions that cannot be changed afterward

There are no setters. Every one of these is permanent.

**`SURPLUS_SINK`** — where mistakenly-sent tokens go. Anyone can trigger the sweep; only
this address ever receives. Wrong value means misdirected tokens are lost permanently.
Use a contract you control, not an EOA you might rotate.

**`OVERLORD` and `OVERSEER`** (door only) — the 61.8% / 38.2% φ split. `LUVLockerDoor` had
`setOverseer`; this does not, because a mutable payee is an admin key wearing a different
hat. If stewardship changes, deploy another door — existing locks are unaffected, since
they live in the storage of whichever contract created them.

**`VERIFIER_ADDR`** (door only) — the biggest one. Two real options:

- Leave it unset. The script deploys a bare `VerifierECDSA` and this door is secp256k1
  **forever**. Simple, correct today, and carries a known expiry date.
- Set it to bankon-vault's `VerifierRegistry`. The signature scheme can then migrate to a
  post-quantum verifier behind that registry's 180-day timelock, without moving a single
  locked token.

Choose deliberately. A lock written for ten years should not hardcode a primitive whose
failure mode is well understood. See `technical.md` §2.

**Maturity, per lock** — `unlock_at` is set at `lock` time and can only ever be pushed
later. Capped at 3,650 days from now.

---

## 4. Deploying

```sh
export SURPLUS_SINK=0x...
export OVERLORD=0x...
export OVERSEER=0x...
# export VERIFIER_ADDR=0x...   # optional; omit for a permanent-ECDSA door

make fork      # dry run against mainnet state. Read the output. Then:
make deploy
```

Rehearse on a testnet first, end to end, including a sweep to `SURPLUS_SINK`. The sweep
is the only way to confirm that argument is right, and it is the one you cannot fix.

---

## 5. Locking a Uniswap V2 LP position

A UNI-V2 pair is itself an ERC-20; its LP tokens *are* the claim on the pooled reserves.
Locking them makes the liquidity unremovable until maturity — for everyone, including the
treasury that locked it.

```sh
PAIR=0x...            # the Uniswap V2 pair
LOCKER=0x...          # liquidity_locker
AMOUNT=...            # re-read the balance at execution time, never reuse a stale figure
ZERO=0x0000000000000000000000000000000000000000

# Rehearsal — lock dust first, end to end, before committing the position.
cast send $PAIR   "approve(address,uint256)" $LOCKER 1000000000000000
cast send $LOCKER "lock_default(address,uint256,address)" $PAIR 1000000000000000 $ZERO
# Confirm the `locked` event. Note the id. Only then:

cast send $PAIR   "approve(address,uint256)" $LOCKER $AMOUNT
cast send $LOCKER "lock_default(address,uint256,address)" $PAIR $AMOUNT $ZERO   # 90 days
```

`lock_default` takes the house default of **ninety days**, which is the right first
commitment precisely because extending is trivial and shortening is impossible:

```sh
cast send $LOCKER "extend_default(uint256)" $ID          # +90 days on the current maturity
cast send $LOCKER "extend_by(uint256,uint256)" $ID 31536000   # +1 year
cast send $LOCKER "lock_for(address,uint256,uint256,address)" $PAIR $AMOUNT 3155760000 $ZERO  # a century, direct
```

To bind the lock to **block height** as well as the clock — consensus alongside the wall
clock, whichever is later governs:

```sh
BLOCKS=2629800        # ~1 year at 12s
cast send $LOCKER "lock_until(address,uint256,uint48,uint40,address)" \
  $PAIR $AMOUNT $(( $(date +%s) + 31536000 )) $(( $(cast block-number) + BLOCKS )) $ZERO

cast send $LOCKER "extend_block_by(uint256,uint256)" $ID $BLOCKS   # extend-only, same as time
cast call $LOCKER "time_remaining(uint256)(uint256,uint256)" $ID   # seconds left, blocks left
```

Passing `address(0)` as the beneficiary means "myself". Pass a real address to lock on
another party's behalf — note that on the free primitive this needs no consent from them,
because it is a gift they can only ever receive. The door requires consent because it
also names a duty: somebody must still be able to sign at maturity.

### Verifying the lock — what anyone can check

1. The `locked(id, beneficiary, token, funder, amount, unlock_at)` event.
2. `pair.balanceOf(locker)` equals the locked amount; the treasury's LP balance drops.
3. `locker.lock_at(id)` returns the maturity and `withdrawn = false`.
4. `locker.is_locked(id)` returns true.

**What locking does not do:** it does not pause trading, does not touch the token
contract, and does not change fees. It removes exactly one power — withdrawing the pooled
reserves before maturity — from everyone, the treasury included.

---

## 6. Operating

**Extend** (`extend(id, new_unlock_at)`) — beneficiary only, forward only. Each extension
is a fresh public commitment and is cheaper and more legible than maturing and re-locking.

**Reassign** (`assign(id, to)`) — hands custody to a new address without unlocking. Use it
when a treasury rotates its multisig. Maturity is untouched. Do this *before* key rotation
becomes urgent; there is no recovery afterwards.

**Sweep** (`sweep_surplus(token)`) — anyone may call, funds go only to `SURPLUS_SINK`.
Reverts if every unit of that token is spoken for, which is the normal state.

**Withdraw** (`withdraw(id)` / `withdraw_to(id, to)`) — beneficiary only, after maturity.
Free, needs no signature and no door.

---

## 7. Emergency procedures

There are none, and that is the design. No pause, no owner, no upgrade.

What is actually available if something goes wrong:

- **A bug in the locker.** Locked funds are reachable only at maturity. Nothing can be
  done before then. Do not deploy without an independent audit.
- **A compromised beneficiary key, before maturity.** Call `assign` from the still-good
  key immediately, to an address the attacker does not control. This is the one real
  emergency lever and it works only while you still hold the key.
- **A compromised beneficiary key, after maturity.** The attacker withdraws. Nothing helps.
- **A hostile verifier on a door.** The door is compromised; the free primitive is not.
  Locks in the door's storage are at risk of forged consent. Locks in `liquidity_locker`
  are untouched, because it has no verifier.
- **Tokens sent by mistake.** `sweep_surplus`, to `SURPLUS_SINK`, by anyone.

---

## 8. Annual review

Assign this to a role, not a person, and put the first date on a calendar.

- [ ] Maturity dates for every live lock, diarized at T−30d and T−7d
- [ ] The re-lock or extension plan published **before** maturity, not after
- [ ] `pair.balanceOf(locker)` still equals the sum of live locks
- [ ] Beneficiary keys still signable — test with a signature, do not assume
- [ ] Verifier still the intended one; if it is a registry, check for pending proposals
- [ ] Cryptographic posture reviewed: is secp256k1 still the right scheme for the
      remaining horizon of the longest live lock?
