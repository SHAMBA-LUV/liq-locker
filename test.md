# test.md — liq-locker

Every test, what it actually proves, and whether it passes.

```
forge test    →  54 passed · 0 failed · 0 skipped · 3 suites
solc 0.8.24 · via_ir · optimizer 200 · evm_version = paris
```

**54 / 54 ✅** — last run 2026-08-05.

A ✅ here means the test was executed and passed, not that it was written. Anything
unverified is listed in §4 and carries no checkmark.

---

## 1. `test/liquidity_locker.t.sol` — the primitive · 25 ✅

### Inherited audit findings

| ✅ | Test | What it proves |
|:--:|---|---|
| ✅ | `test_A1_StrangerCannotExtendSomeoneElsesLock` | A third party cannot push another holder's maturity out. In the live vault the owner could do this repeatedly, ten years per call — indistinguishable from confiscation |
| ✅ | `test_A2_LpLockIsExtendable` | A lock can be lengthened in place. The live vault could not, so proving continued commitment meant maturing, withdrawing and re-locking — publishing an unlocked window in the middle |
| ✅ | `test_A3_TreasuryLocksForCommunityWallet` | A treasury can lock on another address's behalf, and afterwards the *funder* is a stranger to the lock. Only the beneficiary can withdraw |
| ✅ | `test_A4A5_NoPrivilegedPathReachesLockedPrincipal` | The deployer — the most privileged address that exists here — has no path to a locked token. This is why A4 and A5 are "not applicable" rather than "fixed" |

### Core behaviour

| ✅ | Test | What it proves |
|:--:|---|---|
| ✅ | `test_LockThenWithdrawAtMaturity` | The round trip: balances, `total_locked`, and `is_locked` all agree before and after |
| ✅ | `test_CannotWithdrawOneSecondEarly` | The maturity guard is exact, not approximate |
| ✅ | `test_OnlyBeneficiaryCanWithdraw` | A stranger with a valid lock id still cannot take it |
| ✅ | `test_DoubleWithdrawReverts` | The `withdrawn` flag is honoured; a matured lock pays exactly once |
| ✅ | `test_ExtendNeverShortens` | Maturity moves forward or reverts. Never backward |
| ✅ | `test_ExtendRespectsMaxDuration` | The ten-year horizon is enforced on extension, re-checked against *now* |
| ✅ | `test_AssignMovesBeneficiaryButNotMaturity` | Custody transfers; the clock does not move. The old beneficiary is immediately powerless |
| ✅ | `test_LocksOfFiltersStaleIndexEntries` | `assign` leaves a stale entry in the per-user index by design, and `locks_of` filters it against the authoritative record |

### Token behaviour that has broken real lockers

| ✅ | Test | What it proves |
|:--:|---|---|
| ✅ | `test_FeeOnTransferCreditsWhatActuallyArrived` | A 5%-burning token credits 950, not 1000. Accounting equals reality |
| ✅ | `test_TwoFeeTokenLockersBothExit` | The failure the measured delta prevents: with nominal crediting the *second* locker cannot exit. Both exit here |
| ✅ | `test_UsdtStyleNoReturnDataTokenWorks` | Tokens that return nothing from `transfer` work end to end. A bare interface call would revert in the ABI decoder |
| ✅ | `test_TokenReturningFalseIsTreatedAsFailure` | A `false` return is a failure, not a silent loss of funds |
| ✅ | `test_ReentrantTokenCannotWithdrawTwice` | A token that calls back mid-transfer is paid once. Also asserts the callback *fired*, so a dud mock cannot make this pass vacuously |

### Surplus sweep

| ✅ | Test | What it proves |
|:--:|---|---|
| ✅ | `test_SweepMovesOnlyUnaccountedBalance` | A stranger triggers the sweep, locked principal is untouched, and the funds go to the immutable sink — not to the caller |
| ✅ | `test_SweepRevertsWhenEverythingIsLocked` | With nothing unaccounted, there is nothing to sweep. The normal state |

### Input bounds

| ✅ | Test | What it proves |
|:--:|---|---|
| ✅ | `test_RejectsMaturityInThePast` | A lock cannot be created already-open |
| ✅ | `test_RejectsBeyondMaxDuration` | The ten-year horizon is enforced at creation |
| ✅ | `test_RejectsZeroSurplusSinkAtDeploy` | The one constructor argument cannot be zero |
| ✅ | `test_UnknownLockIdReverts` | Reading a nonexistent lock reverts rather than returning a zeroed struct that looks like a real, matured, withdrawn lock |

### Fuzz

| ✅ | Test | Runs | What it proves |
|:--:|---|:--:|---|
| ✅ | `testFuzz_BalanceAlwaysCoversTotalLocked` | 4,096 | The solvency invariant across arbitrary lock sequences. If this fails, somebody cannot exit |
| ✅ | `testFuzz_ExtendIsMonotonic` | 4,096 | Maturity is monotonic under arbitrary extension attempts |

---

## 2. `test/liquidity_locker_time.t.sol` — time · 10 ✅

Maturity to the second, extension across elapsed time, and succession over years. All time
moves through the absolute cursor in `TimeBase` — see §5.

| ✅ | Test | What it proves |
|:--:|---|---|
| ✅ | `test_WithdrawRevertsOneSecondBeforeMaturity` | At `unlock_at − 1` the lock still holds |
| ✅ | `test_WithdrawSucceedsExactlyAtMaturity` | At exactly `unlock_at` it opens. The guard is `<`, so the boundary second is inclusive — pinned rather than assumed |
| ✅ | `test_LockRejectsMaturityInThePast` | Rejected even after the clock has moved on from deployment |
| ✅ | `test_LockRejectsBeyondTenYearHorizon` | The horizon holds at creation |
| ✅ | `test_ExtendPartwayThroughPushesMaturityOut` | Extended at day 200, the lock is *still* shut at the original one-year mark and opens only at the new date. The extension is real, not cosmetic |
| ✅ | `test_ExtendCannotShortenAfterTimePasses` | Elapsed time does not create a shortening path |
| ✅ | `test_ExtendRejectsBeyondTenYearHorizonOverTime` | The horizon is re-measured from *now*, not from lock creation, so repeated extensions cannot ratchet past a decade |
| ✅ | `test_TenYearHorizonLockAndWithdraw` | A full 3,650-day lock: shut one second short of the decade, open one second later |
| ✅ | `test_AssignHandsCustodyButMaturityIsUntouched` | A treasury rotates custody to a DAO multisig mid-lock with no unlocked interval. Past maturity the old beneficiary is refused and the new one is paid |
| ✅ | `test_AssignBeforeMaturityStillRespectsTheClock` | Reassignment is not an early exit for the new holder |

---

## 3. `test/locker_door.t.sol` — the signed door · 19 ✅

### The φ fee

| ✅ | Test | What it proves |
|:--:|---|---|
| ✅ | `test_LockYourOwnChargesPhiFeeAndSplitsIt` | 61.8% / 38.2%, and the remainder arithmetic strands no wei |
| ✅ | `test_UnderpaidFeeReverts` | One wei short is short |
| ✅ | `test_OverpaymentIsRefundedInTransaction` | Overpayment comes back in the same transaction; only the fee is kept |
| ✅ | `test_CollectFeesIsPullPayment` | Payees pull; collecting twice reverts |
| ✅ | `test_RevertingPayeeCannotBrickTheDoor` | A payee that reverts on receive still accrues, and locking keeps working for everyone else. This is *why* fees are pulled and never pushed |
| ✅ | `testFuzz_PhiFeeNeverExceedsCap` (4,096 runs) | φ < 3, so BANKON's `MAX_FEE_NUM = 3` ceiling holds across the whole gas-price range — a future edit to `PHI_WAD` cannot quietly break it |

### Consent

| ✅ | Test | What it proves |
|:--:|---|---|
| ✅ | `test_LockWithConsentNeedsTheBeneficiarySignature` | The signer owns the lock; the funder does not |
| ✅ | `test_NobodyCanBeLockedForWithoutConsent` | A signature from the wrong key is refused. Nobody is assigned a decade-long duty silently |
| ✅ | `test_ConsentIsBoundToTheNamedFunder` | The digest commits to the funder, so a signature harvested from the mempool cannot be reused by a different one |

### Opening the door

| ✅ | Test | What it proves |
|:--:|---|---|
| ✅ | `test_AnyRelayerMayCarryTheOpenOrder` | A stranger submits and pays the gas; proceeds go where the signature says and the relayer earns nothing |
| ✅ | `test_OpeningTheDoorIsFree` | No fee accrues on exit. `open_door` is not even payable |
| ✅ | `test_OpenDoorStillRespectsMaturity` | A valid signature does not shorten the clock |
| ✅ | `test_ExtendBySigIsExtendOnly` | Extend-only holds on the signed path too |

### Replay, expiry, and signers

| ✅ | Test | What it proves |
|:--:|---|---|
| ✅ | `test_SignatureCannotBeReplayed` | The nonce is consumed; the same bytes are worthless afterwards, and a second lock is untouched |
| ✅ | `test_ExpiredSignatureRejected` | Deadlines are enforced |
| ✅ | `test_SignatureFromAnotherChainIsRejected` | The domain separator binds chainid — free cross-chain replay protection |
| ✅ | `test_Erc1271ContractSignerCanOwnAndOpenALock` | **The test a `(v, r, s)` door could not be made to pass.** A contract cannot produce a secp256k1 signature, so `(v, r, s)` silently excludes every multisig, smart account, and EIP-7702 delegated EOA from being a beneficiary — including `bankon.eth` |
| ✅ | `test_ConstructorRejectsZeroAddresses` | No zero payee, no zero verifier |
| ✅ | `test_BaseWithdrawIsStillFreeAndUngated` | If every door function broke tomorrow, every beneficiary could still get out. This is what keeps the fee non-coercive |

---

## 4. Not covered — no checkmark, because it has not been run

Listed here rather than left as a gap someone discovers later. Full detail in `AUDIT.md` §5.

| | Gap | Why it matters |
|:--:|---|---|
| ☐ | Stateful invariant fuzzing over random operation sequences | The current fuzz tests are sequential, not adversarially interleaved |
| ☐ | Differential fuzz of `ECDSALib` against OpenZeppelin's `ECDSA` | Inherited unwritten from bankon-vault, where it is also the highest-value missing test |
| ☐ | Mainnet-fork rehearsal against a real UNI-V2 pair | Every token here is a mock |
| ☐ | A deliberately hostile verifier | The trust assumption in `AUDIT.md` §3 is asserted, not demonstrated |
| ☐ | `locks_of` gas at 100 / 1,000 / 10,000 locks | The O(n) bound is described but never measured |

---

## 5. Two hazards these tests are written around

**`via_ir` caches `block.timestamp`.** Chained `vm.warp(block.timestamp + X)` silently
reuses the first value — three warps of +100 seconds advance the clock by 100, not 300.
Every test here moves time through the absolute cursor in `test/time_base.sol`
(`_startClock`, `_advance`). Never chain relative warps.

**`vm.expectRevert` is consumed by external calls in argument expressions.**
`test_ExtendRespectsMaxDuration` and `test_RejectsBeyondMaxDuration` were first written
with `L.MAX_LOCK_DURATION()` inline in the argument list. That staticcall ate the cheatcode
and both tests **passed while asserting nothing**. They only failed once the reads were
hoisted into locals — the bug surfaced when the tests were made correct, not before.

This is why the ✅ column above records execution rather than authorship: a test that
passes is not automatically a test that checks anything.

---

## 6. Reproducing

```sh
make test                 # all 54
make audit                # the regression subset for the inherited findings
forge test --match-path 'test/liquidity_locker_time.t.sol' -vvv
python3 ../scripts/check_test_md.py     # verifies this file against a live run
```
