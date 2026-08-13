# AUDIT.md — liq-locker

Self-audit. Findings were inherited from the SHAMBA LUV `LUVLocker` review of 2026-08-03
and re-decided here; each one was written as a test before it was called fixed.

Self-audited by compiling and executing, not by reading. That is not a substitute for an
independent audit, and this document is not one.

---

## 1. Inherited findings and what was done with them

| ID | Severity | Original finding | Disposition here |
|---|---|---|---|
| A1 | Medium | Owner could extend **any** depositor's lock, +10 years per call — a hostage mechanism | **Removed the owner.** `extend` is beneficiary-only and there is no third-party path |
| A2 | Low | Asset locks were not extendable; proving continued commitment meant maturing, withdrawing, re-locking | **Fixed.** `extend` is extend-only, capped at `MAX_LOCK_DURATION` |
| A3 | Low/UX | Locks bound to the funder, so a treasury could not lock for a community wallet | **Fixed.** `beneficiary` is an argument; `assign` moves it later without unlocking |
| A4 | Info | No incident brake of any kind | **Not applicable.** There is no owner to operate a brake. See §3 |
| A5 | Info | Single-step ownership transfer | **Not applicable.** No ownership to transfer |

`LUVLockerModern` answered A1/A4/A5 by constraining what the owner may do —
self-only extension, `Pausable` deposits with never-pausable exits, `Ownable2Step`.
That is a correct fix for a contract that needs an owner. This one does not, so the
answer here is subtraction rather than constraint. Three findings, one deletion.

**Regression tests:** `test_A1_StrangerCannotExtendSomeoneElsesLock`,
`test_A2_LpLockIsExtendable`, `test_A3_TreasuryLocksForCommunityWallet`,
`test_A4A5_NoPrivilegedPathReachesLockedPrincipal`.

---

## 2. Properties verified to hold

| Area | Verdict | Test |
|---|---|---|
| Fee-on-transfer safety | Both credit paths use the **measured balance delta**, never the requested amount | `test_FeeOnTransferCreditsWhatActuallyArrived`, `test_TwoFeeTokenLockersBothExit` |
| Non-compliant ERC-20s | USDT-style no-return tokens work; `false`-returning tokens are treated as failure | `test_UsdtStyleNoReturnDataTokenWorks`, `test_TokenReturningFalseIsTreatedAsFailure` |
| Reentrancy | Mutex on every mutator; effects (including the `withdrawn` flag) precede every transfer | `test_ReentrantTokenCannotWithdrawTwice` |
| Read-only reentrancy | Views carry `when_not_entered`, so an integrator cannot be fed mid-call state | — (guard applied to all views) |
| Owner containment | No owner exists; sweeps are excluded from locked principal arithmetically | `test_SweepMovesOnlyUnaccountedBalance`, `test_SweepRevertsWhenEverythingIsLocked` |
| Extend-only | Maturity moves forward or reverts, never backward, on every path | `testFuzz_ExtendIsMonotonic`, `test_ExtendNeverShortens` |
| Solvency | Balance never falls below `total_locked` across arbitrary lock sequences | `testFuzz_BalanceAlwaysCoversTotalLocked` |
| Consent | Nobody can be made a beneficiary without their signature; consent is bound to the named funder | `test_NobodyCanBeLockedForWithoutConsent`, `test_ConsentIsBoundToTheNamedFunder` |
| Replay | Per-signer nonce shared across all three door verbs; chainid in the domain separator | `test_SignatureCannotBeReplayed`, `test_SignatureFromAnotherChainIsRejected` |
| Fee ceiling | φ < 3, so `MAX_FEE_NUM = 3` holds by construction across the whole gas-price range | `testFuzz_PhiFeeNeverExceedsCap` |
| Exit is unconditional | Base `withdraw` needs no fee, no signature, no relayer, and no door function to work | `test_BaseWithdrawIsStillFreeAndUngated`, `test_OpeningTheDoorIsFree` |

### Time properties (`test/liquidity_locker_time.t.sol`, 10 tests, added 2026-08-05)

| Area | Verdict | Test |
|---|---|---|
| Maturity boundary | Reverts at unlock−1s; opens exactly at unlock | `test_WithdrawRevertsOneSecondBeforeMaturity`, `test_WithdrawSucceedsExactlyAtMaturity` |
| Lock-time validation | Rejects a maturity in the past and beyond the ten-year horizon | `test_LockRejectsMaturityInThePast`, `test_LockRejectsBeyondTenYearHorizon` |
| Extend across time | A mid-term extension holds past the original maturity to the new one; cannot shorten; horizon re-checked against `now` | `test_ExtendPartwayThroughPushesMaturityOut`, `test_ExtendCannotShortenAfterTimePasses`, `test_ExtendRejectsBeyondTenYearHorizonOverTime` |
| Ten-year horizon | A full-decade lock matures and withdraws end to end | `test_TenYearHorizonLockAndWithdraw` |
| Succession over time | `assign` moves who may open the lock, never when; the old beneficiary is locked out even past maturity, the new one still waits for the clock | `test_AssignHandsCustodyButMaturityIsUntouched`, `test_AssignBeforeMaturityStillRespectsTheClock` |

---

## 3. Accepted risks — deliberately not fixed

**No pause, no brake, no emergency anything.** If a bug is found in this contract after
deployment, nobody can stop it, including the author. That is the cost of removing the
owner and it is paid knowingly: an owner who can pause is an owner who can be coerced
into pausing, and a liquidity lock whose operator can freeze exits is not a lock. Exits
in particular must work on the worst day, when whoever would have held the pause key is
exactly the party you needed protection from.

**`SURPLUS_SINK` is fixed forever.** A wrong constructor argument is unrecoverable —
misdirected tokens go to the wrong address permanently. Mitigated only by procedure:
`usage.md` §3 makes it a pre-deploy checklist item, and the rehearsal in `usage.md` §4
verifies it on a testnet first.

**Rebasing-down tokens under-deliver.** A lock credits the delta received at lock time.
If the token later *reduces* balances, `total_locked` exceeds the real balance and the
last withdrawer comes up short. There is no honest fix inside the locker — the shortfall
is real, and pro-rata haircutting would silently change what a lock means. Do not lock
rebasing tokens. UNI-V2 pair tokens are not rebasing.

**`tx.gasprice` sets the φ fee, and the caller chooses `tx.gasprice`.** The fee is
adjustable downward by anyone willing to transact at a low gas price, and is zero at a
gas price of zero. This is the design, not a leak: the fee is proportional to the cost of
the service at the moment it is used. It is documented in `phi_fee` so that nobody mistakes
it for a floor.

**`locks_of` is O(n) and unbounded.** An address with thousands of locks makes it too
expensive to call. It is an `eth_call` convenience for the UI, guarded by
`when_not_entered`, and no contract logic depends on it. Never call it on-chain.

**The `_index_of` mapping goes stale by design.** `assign` appends to the new
beneficiary and never removes from the old, because removal from a dynamic array is
either O(n) or reorders ids. `locks_of` filters against the authoritative record, which
is the `_locks` mapping. Never treat `_index_of` as truth.
`test_LocksOfFiltersStaleIndexEntries` pins the behaviour.

**The verifier is trusted absolutely.** `locker_door` believes whatever
`ISignatureVerifier.verify` returns. A malicious or buggy verifier forges consent and
opens doors. It is immutable per door, so the risk is entirely in the deploy-time choice —
which is also what makes pointing it at bankon-vault's timelocked `VerifierRegistry`
meaningful rather than decorative.

---

## 4. Testing hazards hit while writing this

**T-4 — a paris profile cannot call cancun bytecode.** Forking mainnet under this repo's
default `evm_version = "paris"` makes every call into a modern deployed contract fail with
`EvmError: NotActivated` (LUV's PUSH0). The fork rehearsal runs under `[profile.fork]`
(cancun) while deployment stays paris. Diagnosing that from the error text alone is
unpleasant, which is why it is written down here.

**T-1 — `via_ir` caches `block.timestamp`.** Chained `vm.warp(block.timestamp + X)` in one
test function silently reuses the first value. All tests use the absolute cursor in
`test/time_base.sol`, copied from bankon-vault. Never chain relative warps.

**T-2 — `vm.expectRevert` is consumed by external calls in argument expressions.** Two
bound tests here were written as
`vm.expectRevert(...); L.lock(..., _now() + uint48(L.MAX_LOCK_DURATION()) + 1, ...)`,
where `L.MAX_LOCK_DURATION()` is a staticcall that eats the cheatcode. Both **passed
vacuously** on the first run and only failed once the reads were hoisted into locals —
which is to say the bug was found by the tests failing *after* being made correct, not
before. Hoist every read above the cheatcode. Same family applies to `vm.prank`.

**T-3 — deadlines must outlive the warp.** Two door tests computed
`deadline = T + 1 hours` and then advanced a year before submitting, so they failed with
`signature_expired` while claiming to test something else. Compute deadlines in absolute
terms against the final cursor position.

---

## 4a. The two gates, the ninety-day default, and easy extension (2026-08-12)

Added after the operator asked for a 90-day default, easy extension, and locks that reach
centuries under both an accurate clock and block height.

| Change | Why it is not a new attack surface |
|---|---|
| `DEFAULT_LOCK_DURATION = 90 days` · `lock_default` · `lock_for(duration)` | Sugar over the same `_lock_from`. Every bound the absolute form enforced is enforced here, because they are enforced in `_lock_from` and nowhere else. `lock_for` rejects 0 and anything past `MAX_LOCK_DURATION`. |
| `extend_by` · `extend_default` | Both compute a target and route into the unchanged `_extend_for`, which owns the extend-only rule and the horizon cap. They add to the CURRENT maturity, never to `now`, so extending late cannot shorten a lock — `test_ExtendByAddsToMaturityNotToNow`. |
| `unlock_block` (uint40, same slot: 160+48+8+40 = 256) | A SECOND gate, never a replacement. `withdraw` requires BOTH `block.timestamp >= unlock_at` AND `block.number >= unlock_block`; an unset gate is 0 and therefore already passed. Adding a gate can only ever delay an exit. |
| `extend_block` · `extend_block_by` | Same authority (`beneficiary` only), same one-way rule, same horizon (`MAX_LOCK_BLOCKS`). A time-only lock may ACQUIRE a block gate and can never lose it. |
| `MAX_LOCK_BLOCKS = 2e9` | ~760 years at 12s, ~127 at 2s, ~31 on a 0.5s L2; uint40 holds 1.0995e12. The fat-finger bound the time horizon already had, in the other unit. |

**Why two gates.** A timestamp is a proposer's claim about the wall clock and moves within a
tolerance; block height is consensus itself, monotone, and cannot be nudged. Requiring both
means a lock cannot be opened early by a clock, and cannot be stranded by a chain that
changes cadence — if blocks slow, the time gate still governs; if they speed up, the block
gate does. Neither gate can be brought forward by anyone, which is checked directly
(`test_NoGateCanEverBeBroughtForward`) and under fuzzing (§5a, invariants 3 and 4).

Regression suite: `test/liquidity_locker_gates.t.sol`, 27 tests — the default to the second,
quarters compounding into centuries, both gate orders, block-only locks, horizons, extension
authority, and a century under both gates carried to maturity and withdrawn.

## 5a. Stateful invariant fuzzing — WRITTEN (was §5's highest-value gap)

`test/liquidity_locker_invariant.t.sol` drives the vault with random sequences of every
mutating operation (all four lock forms, all four extends, assign, withdraw, redeem, sweep)
interleaved with random reflections and random advances of **both** clocks. Six invariants,
each at **512 runs × 64 calls = 32,768 calls, zero reverts**:

| # | Invariant | What it forbids |
|---|---|---|
| 1 | `balance >= total_locked` | insolvency |
| 1b | `balance >= total_locked + promised` | promising interest the vault does not hold |
| 2 | `total_locked == Σ live principal` | book drift |
| 3 | `ghost_gate_reversals == 0` | **any gate, on any lock, ever moving backwards** |
| 4 | `ghost_early_exits == 0` | **any withdrawal while either gate still held** |
| 5 | sink balance ≤ supply − locked | the permissionless sweep reaching principal |

(3) and (4) are checked against ghost state the handler records **at call time**, not
re-derived from the contract, so a bug that rewrote a gate could not hide behind its own
accounting. `afterInvariant` asserts each run actually created locks and extended or
withdrew — a vacuous run fails rather than passes.

## 5b. The mainnet-fork rehearsal — WRITTEN (was §5)

`test/liquidity_locker_fork.t.sol`, 7 tests, run with `make fork-test`. It forks Ethereum
and locks the **real Uniswap V2 LUV/WETH pair token** (`0x57D2085A...8a31`) held by the
**real treasury** (bankon.eth), at whatever balance the chain reports when the test runs.
Nothing is hardcoded but the addresses — amounts, reserves and supply are read from the
fork, so the rehearsal keeps telling the truth as the chain moves instead of going stale.

| # | Test | What the fork proves that a mock cannot |
|---|---|---|
| 1 | `TheRealPairIsWhatWeThinkItIs` | token0 == LUV, token1 == WETH, and the treasury holds `totalSupply - 1000` — i.e. **100% of circulating LP**, the MINIMUM_LIQUIDITY burn being the only other holder |
| 2 | `RehearsalDustLockClearsEndToEnd` | the runbook's 0.001 LP rehearsal: approve → `lock_default` → 90-day gate → mature → withdraw, and the dust comes back whole |
| 3 | `LockingTheFullPositionMakesLiquidityUnremovable` | the entire position locked; treasury LP goes to **0**; `pair.burn(treasury)` **reverts**; and the pool's own reserves are **unchanged** — locking LP moves the claim, never the liquidity |
| 4 | `ExtensionOnTheRealPositionIsOneWay` | `extend_default` + `extend_block_by` on the live position, then both gates refuse to walk back; the time gate opening does not open the lock while the block gate holds |
| 5 | `NobodyElseCanTouchTheRealPosition` | a stranger cannot withdraw/extend/assign; `sweep_surplus` reverts `nothing_to_sweep`; **the treasury itself cannot open it early**; succession moves who, never when |
| 6 | `ACenturyOnTheRealPairMaturesAndReturns` | both gates a century out, one second short still shut, then the whole position returns |
| 7 | `RealLuvCreditsTheMeasuredDelta` | the credit equals what **actually arrived** from the real reflection token, read from it rather than assumed |

**A finding, from running it.** The first attempt failed with `EvmError: NotActivated` on a
`balanceOf` of the real LUV token. Cause: this repository builds for **paris** —
deliberately, because paris bytecode runs on every chain including those that never took
shanghai — while mainnet is cancun and LUV is compiled for it, so its PUSH0 is not an opcode
a paris EVM will execute. Deployment target and rehearsal target are different questions, so
they now get different answers: a `[profile.fork]` with `evm_version = "cancun"` runs the
rehearsal, and the default profile still produces the portable paris bytecode that is
deployed. Recorded as hazard T-4 in §4.

The suite is **skipped unless `FORK_TEST=1`**, so an offline build can never fail on it, and
it forks at HEAD by default (`FORK_BLOCK` pins a height; an archive node is needed once that
height ages out of the recent-state window).

## 5c. The last three gaps — WRITTEN (2026-08-13)

All three items previously listed as "still to write" are done. None of them found a
vulnerability; the second one demonstrated an accepted risk, and the third produced a number
the UI needs. What remains before mainnet is an **independent audit**, which is not a test.

**Differential fuzz of `ECDSALib` against OpenZeppelin** — `test/ecdsa_differential.t.sol`,
8 tests at 4,097 runs each = **32,776 signature comparisons**. OpenZeppelin's `ECDSA` v5.7.0
is vendored verbatim into `test/reference/OZ_ECDSA.sol` for tests only; nothing in `src/`
imports it and it never enters deployed bytecode. Result: **full agreement wherever it
matters** — over honest signatures, over arbitrary bytes, and over a real signature with each
field independently corrupted, the two never return different nonzero signers, and ours never
accepts anything OpenZeppelin refuses. The three specific hazards are pinned separately: the
EIP-2 high-s twin is refused by both, every `v` outside {27, 28} is refused by both, every
length but 65 is refused by both, and `isValidSignatureNow(address(0), …)` is false for all
input — the trap that would otherwise turn a malformed signature into "anyone may sign".

*Vendored rather than submoduled for a second reason: OpenZeppelin's repo carries its own
`foundry.toml` pinning an `evm_version` this toolchain does not recognise, and foundry reads
nested configs when resolving remappings. Recorded as hazard T-5.*

**The malicious verifier** — `test/malicious_verifier.t.sol`, 7 tests. An unusual file: here
a PASS means the attack SUCCEEDED, because §3 accepts in writing that the verifier is trusted
and an accepted risk that has never been demonstrated is just a sentence. A `yes_verifier`
returning `true` for everything forges consent completely — with a **zero-byte signature** an
attacker withdraws a victim's matured lock to themselves (`open_door`), adds nine years to a
victim's maturity (`extend_by_sig`), and binds a victim as beneficiary without their
participation (`lock_with_consent`).

Two boundaries are proven alongside it, and they are why this is an accepted risk rather
than a defect. **The blast radius stops at the door**: `liquidity_locker` takes no verifier,
so a lock made directly against it — which is what the LP position will be — is untouched by
any of this. And **a hostile verifier forges WHO, never WHEN**: the gates live in the
locker's storage and take no signature, so a forged instruction still waits for maturity.

> **Operational consequence.** Verifying `locker_door` on Etherscan is NOT sufficient to
> trust it. The door's own source can be flawless while the address it points at is hostile.
> Whoever audits a deployed door must read `VERIFIER()` and verify THAT contract too. §6's
> "verifier choice made deliberately" is not a formality; it is the entire trust boundary.

**The `locks_of` gas bound** — `test/locks_of_gas.t.sol`, 5 tests. Measured, not estimated:

| locks | gas | per lock | against a 30M block |
|---|---|---|---|
| 100 | **195,043** | 1,950 | 0.7% |
| 1,000 | **1,949,048** | 1,950 | 6.5% |
| 10,000 | **21,577,308** | 2,158 | **72%** |

Growth is **linear** and asserted so (per-lock cost is flat from 100 to 1,000). The practical
ceiling is the node's `eth_call` cap, not a block: 10,000 locks fits comfortably under a 50M
cap and is nowhere near Alchemy/Infura's higher ceilings, so **a UI can call `locks_of`
directly up to roughly ten thousand locks per beneficiary** and should paginate beyond that.

One thing a UI author must know: the index is append-only and `assign` never prunes it. A
lock that changes hands leaves a stale entry in the old beneficiary's list, filtered out of
the result but still walked — 200 fully-assigned-away locks still cost **244,272 gas** to
return an empty array. The cost tracks entries ever indexed, not locks currently held.

## 6. Pre-mainnet checklist

- [x] `make sizes` — every contract under 24,576 bytes (2026-08-12: liquidity_locker **8,335 B**,
      locker_door **11,881 B**; margins 16,241 and 12,695)
- [ ] `SURPLUS_SINK` verified, on a testnet, by actually sweeping to it
- [ ] The `beneficiary` for each planned lock is a contract you control, or a key you can
      still sign with at maturity — locks outlive the wallets people expect them to
- [ ] Verifier choice made deliberately: bare `VerifierECDSA` or a `VerifierRegistry`
- [ ] Rehearsal lock of a token dust amount, end to end, before the real position
- [ ] Maturity diarized at T−30d and T−7d, with the re-lock plan published *before* it
- [ ] Independent audit
