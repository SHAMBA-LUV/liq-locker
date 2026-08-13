# GATE ATTACK — results

An adversarial pass at the **time element** of both lockers, run 2026-08-13.

Both vaults make the same promise: *maturity cannot be brought forward by anyone, including
the deployer*. The existing suites prove the lockers work. This pass tried to break them —
each test is written as an attacker, so **a PASS means the attempt failed**.

## Totals

| suite | profile | tests | result |
|---|---|---|---|
| liq-locker, full | default (paris, hermetic) | **151** | 151 passed · 0 failed · 1 skipped¹ |
| liq-locker, mainnet fork | `make fork-test` (cancun) | **7** | 7 passed · 0 failed |
| luv-locker, full | default | **50** | 50 passed · 0 failed |
| **total** | | **208** | **208 passed · 0 failed** |

¹ the fork rehearsal is skipped in the hermetic profile by design; it runs green under
`make fork-test` (row 2), against the **real** Uniswap V2 LUV/WETH pair at chain HEAD.

New in this pass: `liq-locker/test/gate_attack.t.sol` (**28**) and
`luv-locker/test/gate_attack.t.sol` (**17**) — 45 adversarial tests.

## What was attacked, and what held

### The time gate
- withdrawal one second early — **refused** (both lockers)
- withdrawal exactly at maturity — **allowed**, and principal returns whole
- **proposer drift**: a validator nudging `block.timestamp` by 1–900s to buy an early
  release — **refused at every offset**. The gate is `block.timestamp < unlock_at`, so
  drift cannot cross it; it can only move the moment the honest release becomes possible.

### The block gate (liq-locker) and the block lock (luv-locker)
- one block early — **refused**, even with the clock run 10 years forward
- two centuries of `vm.warp` against an unmet block gate — **refused**. Block height is
  consensus, not a proposer's claim, and no amount of clock buys a block.

### "The later gate governs"
- time passed, block not → **shut**
- block passed, time not → **shut**
- both passed → **opens**

That is the whole point of two gates: a lock cannot be opened early by a clock, and cannot
be stranded by a chain that changes cadence.

### Extend-only
Every path that writes maturity refuses to lower it: `extend` to earlier **and to equal**,
`extend_by(0)`, `extend_block` to earlier, and extending **late** (which adds to the current
maturity, not to `now`, so a late extension cannot silently shorten a lock). Overflow at the
`uint48`/`uint40` horizons reverts rather than wrapping into the past — see the finding below.

### Authority and succession
Strangers cannot withdraw, redirect a payout, extend, or assign. Double-withdraw is refused.
`assign` **moves** the right to open rather than copying it — the old beneficiary is locked
out immediately — and it does not move maturity, so succession is not an early exit.
Assigning to `address(0)` is refused, so a lock cannot be stranded.

`luv_locker.extend_lock` is **self-only** (audit A1): in the live vault an owner could add
ten years to any depositor's lock, repeatedly — a hostage mechanism. There is no owner here
and no third-party path, and the test confirms Mallory calling it reverts while Alice still
exits on her own schedule.

### Re-entrancy and custody
A hostile token re-entering `withdraw` mid-transfer is **refused**. The permissionless
`sweep_surplus` cannot reach locked principal; `sweep_foreign` **cannot take LUV at all**.
In the LUV vault, interest is harvestable mid-lock while principal stays put.

### C-1 — the finding that is a live theft
This is the one that matters. The live `LUVLocker 0xe07ACAde…B898` credits the **measured
balance delta** on deposit. LUV rebases *upward during a transfer* (`_processFees` runs at
the top of `_transfer`), so a dust deposit timed into a pending fee flush is credited with
the whole reflection as principal — buying every existing depositor's yield for 1 wei.

`test_attack_C1_DustDepositCannotAbsorbAReflection` runs exactly that attack against the
rewrite, with a mock that reflects *inside* `transferFrom`:

- Mallory's principal after depositing 1 wei into a 500,000 LUV flush: **1 wei**, not
  500,000e18 + 1.
- The reflection lands on the principal that existed when it was earned: Alice keeps
  **≥99.9%**, Mallory retro-earns **≤0.0001%**.

The rewrite caps the credit at what was asked and folds the surplus into the index pro-rata
*before* striking the new depositor's debt. **The attack does not work.**

## Findings

**1 — informational, no severity.** In `liquidity_locker.extend_by` / `extend_block_by`, an
absurd `extra` (`type(uint256).max`) overflows the checked add **before** the explicit
`timestamp_overflow()` guard can run, so the caller sees a bare panic `0x11` instead of the
named error and the named error is unreachable at that input. **The security property is
unaffected**: it still reverts, nothing wraps, and maturity is unchanged after the revert —
both are asserted. Just past the type horizon (`type(uint48).max` / `type(uint40).max`) the
named guard fires correctly. Cosmetic only; fix by bounding `extra` before the add if the
named error is wanted everywhere.

**Not a finding — operator note.** In `luv_locker`, a top-up **re-locks the whole balance**
for a fresh term. Depositing 1 wei a day before maturity restarts the full 90 days on
everything. This is by design (the lock is per-account, not per-deposit) and it is *not* a
griefing vector, because there is no `deposit_for(other)` — only you can do it to yourself.
It is pinned by `test_attack_TopUpRelocksTheWholeBalance` so it can never become one
silently. Worth saying out loud in any depositor-facing UI.

**Correction to an earlier claim of mine.** Running the fork suite on the default profile
produces `EvmError: NotActivated` on real LUV. That is not a defect: the default profile is
deliberately **paris** (the bytecode the locker deploys, portable to every chain) while the
fork rehearsal needs **cancun** (what mainnet is, and what LUV is compiled for). The repo
already handles this — `make fork-test` sets `FOUNDRY_PROFILE=fork`, and the split is
documented in `foundry.toml`. Use the make target; a bare `FORK_TEST=1 forge test` will
mislead you.

## What this does and does not establish

It establishes that the **time and block gates are sound** under boundary conditions,
proposer drift, extension abuse, authority confusion, re-entrancy and arithmetic limits —
and that **C-1 does not reproduce** against the rewrite.

It does **not** replace an independent audit. Both repos' own AUDIT.md still have unticked
sections: liq-locker §5 wants an ECDSALib differential fuzz, a malicious-verifier
demonstration and a `locks_of` gas bound, with §6 (independent review) open; luv-locker §7
wants invariant fuzzing, an excluded-mid-life test and a numeric dust bound. `luv_locker`
remains marked **NOT mainnet-cleared** by its own record, and nothing here changes that.

Reproduce:

```
cd liq-locker && forge test && make fork-test
cd luv-locker && forge test
```
