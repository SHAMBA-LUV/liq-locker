# technical.md — liq-locker

Architecture, threat model, and the reasoning behind every non-obvious choice.

---

## 1. System shape

```
   ┌──────────────────────────┐
   │  ISignatureVerifier      │  the crypto-agility seam
   │  VerifierECDSA  ──or──   │  bare, permanent secp256k1
   │  VerifierRegistry        │  bankon-vault's 180d timelocked swap
   └────────────┬─────────────┘
                │ verify(signer, digest, bytes)
   ┌────────────▼─────────────┐
   │      locker_door         │  EIP-712 consent · relay · φ fee
   │      └ liquidity_locker  │  inherited, unchanged
   └──────────────────────────┘

   ┌──────────────────────────┐
   │    liquidity_locker      │  deployed separately, free, ownerless
   └──────────────────────────┘
```

Two independent deployments. The door **is** a locker with extra entrances, not a
front-end to the free one — they do not share storage and a lock belongs to whichever
contract created it. Nothing points back up: `liquidity_locker` has no knowledge of doors,
verifiers, fees, or signatures.

---

## 2. Why the door takes `bytes` and not `(v, r, s)`

`LUVLockerDoor` takes `uint8 v, bytes32 r, bytes32 s` and calls `ECDSA.recover`. That is
a reasonable choice for a contract with a short life. It is the wrong one here, for two
independent reasons.

**A secp256k1 signature is 65 bytes. A post-quantum one is not.** ML-DSA-44 signatures
are 2,420 bytes; SLH-DSA-128s are 7,856. A `(v, r, s)` parameter list cannot express them
at all, so a door built that way can never migrate schemes — not by upgrade, not by
registry, not by anything short of moving every lock to a new contract. For a primitive
whose purpose is a lock measured in years, that is a designed-in expiry date. On the day
secp256k1 falls, such a door still works perfectly and holds the liquidity hostage
forever. The lock becomes a tomb.

**A contract cannot produce a secp256k1 signature.** ERC-1271 exists so that multisigs,
smart accounts, and EIP-7702 delegated EOAs can sign, and it takes `bytes`. A `(v, r, s)`
door silently excludes every contract wallet from being a beneficiary. BANKON's own owner
(`bankon.eth`, `0x10f7Ee…D169`) is an EIP-7702 delegated account. The treasury that would
hold the most important lock is exactly the party a `(v, r, s)` door locks out.

`test_Erc1271ContractSignerCanOwnAndOpenALock` pins the second property.

---

## 3. Why there is no owner

The inherited audit raised five findings. Three of them are findings about an owner:
the owner could extend anyone's lock (A1), there was no brake (A4), ownership transferred
in one step (A5). `LUVLockerModern` fixed all three by constraining the owner — self-only
extension, `Pausable` deposits with never-pausable exits, `Ownable2Step`.

That is a correct fix for a contract that needs an owner. This one does not need one.
Enumerate what an owner would do here: rescue stray tokens (replaced by a permissionless
sweep to an immutable sink), pause in an incident (see below), change lock duration (there
is no global duration — every lock carries its own maturity), transfer ownership (nothing
to transfer). The list empties.

**On the missing pause specifically.** A pause protects depositors from a bug. It also
gives one address the power to prevent exits. For a vault, that trade can be worth making.
For a liquidity lock it cannot: the entire proposition is that the liquidity cannot be
removed early, and an operator who can freeze the contract can freeze it at exactly the
moment a holder needs out. The party you would want protection from on the worst day is
the party holding the pause key. So there is no key, and the cost — an unfixable bug is
unfixable — is paid knowingly and recorded in `AUDIT.md` §3.

---

## 4. Threat model

### In scope, mitigated

| Threat | Mitigation |
|---|---|
| Owner confiscates or extends a user's lock | no owner; `extend` is beneficiary-only |
| Owner drains locked principal | no owner; sweeps exclude `total_locked` arithmetically |
| Griefer sweeps locked tokens to themselves | `SURPLUS_SINK` is immutable; the caller chooses nothing |
| Fee-on-transfer token breaks accounting | every credit is a measured balance delta |
| USDT-style token bricks transfers | `safe_token` treats empty return data as success |
| Token returning `false` silently loses funds | treated as failure, reverts |
| Reentrancy during withdrawal | mutex; `withdrawn` flag set before the transfer |
| Read-only reentrancy against integrators | `when_not_entered` on every view |
| Signature replay, same chain | per-signer nonce shared across all three door verbs |
| Signature replay, another chain | chainid in the EIP-712 domain separator |
| Signature replay after a fork | `EIP712Lib` rebuilds the separator when chainid changes |
| Being made a beneficiary without consent | `lock_with_consent` requires the beneficiary's signature |
| Consent harvested and reused by another funder | the digest commits to the funder |
| Maturity shortened by any path | every path routes through `_extend_for`, which is extend-only |
| Fee runaway | φ < 3, so `MAX_FEE_NUM = 3` holds by construction |
| Payee bricking the contract by reverting on receive | fees are pulled, never pushed |
| Exit gated behind a fee | base `withdraw` is free and needs no door function to work |

### In scope, NOT mitigated — read this

**A bug in this contract is permanent.** No pause, no upgrade, no owner. This is the
deliberate trade described in §3, and it is the largest single risk in the repository.

**A wrong `SURPLUS_SINK` is permanent.** The only constructor argument on the free
primitive, and unrecoverable if wrong.

**The verifier is trusted absolutely.** `locker_door` believes whatever the verifier
returns. A hostile verifier forges consent and opens any door. Immutable per door, so the
entire risk sits in the deploy-time choice.

**Beneficiary key loss is unrecoverable.** A lock maturing in ten years is only useful if
someone can still sign for it in ten years. `assign` lets custody move *before* that
becomes a problem; nothing helps afterwards. This is the same problem bankon-vault's
`SuccessionModule` exists to solve, and pointing a lock's beneficiary at a succession-
governed contract is the intended answer.

**Rebasing-down tokens under-deliver.** See `AUDIT.md` §3. Do not lock them.

**Chain death.** Everything here assumes the chain still processes transactions.

---

## 5. Long-horizon design notes

### Timestamps

| Type | Overflows | Verdict |
|---|---|---|
| `uint32` | **2106** | never — inside the design horizon |
| `uint48` | year 8,921,556 | used for every maturity; packs into the token slot |
| block numbers | n/a | never for durations — block time is not a constant |

`_now48()` reverts rather than truncating. The branch is unreachable and documents the
invariant.

### Storage layout

`lock_record` is three slots: `(token, unlock_at, withdrawn)` packs to 216 bits in one,
then `beneficiary`, then `amount`. `amount` gets a full word rather than being squeezed
next to the beneficiary, because a token with 18 decimals and a large supply is exactly
the case this contract is for and a `uint96` ceiling would be a silent trap.

### Lock ids are global, never per-user

A lock's identity must survive reassignment. If ids were indices into a per-user array,
`assign` would change a lock's id, which breaks every event, every bookmark, and every
external reference to it. `_index_of` is the per-user convenience view, and it is
explicitly not authoritative.

### Classic mutex, not transient storage

`evm_version = "paris"`; the guards use a `uint256` 1/2 flag rather than `TSTORE`/`TLOAD`.
Same reasoning as bankon-vault: for contracts meant to outlive several EVM upgrades, take
the gas and keep the certainty.

### No dependencies at all

`src/in_house.sol` reimplements the ERC-20 helpers rather than importing solmate or
OpenZeppelin. A lock intended to hold liquidity for a decade should not inherit a supply
chain, and the code involved is sixty lines. `forge-std` appears only under `test/`.

### No hardcoded gas, no `SELFDESTRUCT`, no `tx.origin`, no delegatecall, no proxy

EIP-1884 broke every contract relying on the 2300-gas stipend; account abstraction made
`tx.origin` a lie; EIP-6780 already neutered `SELFDESTRUCT`; proxies reintroduce the admin
key this design exists to remove. The ETH refund and fee payout use `.call` with all
available gas, both behind the mutex.

---

## 6. cypherpunk2048 compliance

| Rule | Status |
|---|---|
| Apache-2.0 | yes, every file |
| No admin keys post-deploy | yes — no owner, no roles, no pause, no setters |
| No upgradeable proxies | yes — no delegatecall anywhere |
| Flat snake_case layout | yes — files, contracts, functions, and errors |
| Custom errors, no revert strings | yes |
| Terse plain-text docs | this file |
| Fee hard-capped in the contract | yes — `MAX_FEE_NUM`, satisfied by construction |
| Comment block before `pragma` | yes |
| One `docs/<name>.md` per `.sol` | yes |

**No exception is claimed.** bankon-vault documents exactly one — `VerifierRegistry` is
mutable, because a succession layer that hardcodes ECDSA becomes a tomb. That exception
lives in that module. This one inherits the *interface* to it without inheriting the
mutability: the door's verifier address is immutable, and the swappability, if wanted,
comes from pointing it at a registry that is itself governed elsewhere.

---

## 7. Gas

- `lock`: two `balanceOf` calls plus the transfer, then three cold SSTOREs and an array
  push. The double `balanceOf` is the price of the measured delta and is not optional.
- `withdraw`: one warm SSTORE for the flag, one for `total_locked`, one transfer.
- `extend` / `assign`: one warm SSTORE and one event.
- Door verbs add one `keccak`, one nonce SSTORE, and one external staticcall to the
  verifier — roughly 2,600 gas. That is the price of an unbounded cryptographic future.
- `locks_of` is O(n) and view-only. Never call it on-chain.

Run `make gas` and `make sizes` before every deployment.

---

## 8. Test coverage map

| Area | Test |
|---|---|
| A1 — third party cannot extend | `test_A1_StrangerCannotExtendSomeoneElsesLock` |
| A2 — LP locks are extendable | `test_A2_LpLockIsExtendable` |
| A3 — lock for a beneficiary | `test_A3_TreasuryLocksForCommunityWallet` |
| A4/A5 — no privileged path | `test_A4A5_NoPrivilegedPathReachesLockedPrincipal` |
| Fee-on-transfer credit | `test_FeeOnTransferCreditsWhatActuallyArrived` |
| Fee-on-transfer, both exit | `test_TwoFeeTokenLockersBothExit` |
| USDT-style no return data | `test_UsdtStyleNoReturnDataTokenWorks` |
| `false`-returning token | `test_TokenReturningFalseIsTreatedAsFailure` |
| Reentrant token | `test_ReentrantTokenCannotWithdrawTwice` |
| Sweep excludes principal | `test_SweepMovesOnlyUnaccountedBalance` |
| Sweep destination immutable | same |
| Assign moves custody, not maturity | `test_AssignMovesBeneficiaryButNotMaturity` |
| Stale index filtering | `test_LocksOfFiltersStaleIndexEntries` |
| Solvency under fuzz | `testFuzz_BalanceAlwaysCoversTotalLocked` |
| Maturity monotonic under fuzz | `testFuzz_ExtendIsMonotonic` |
| φ split and no stranded wei | `test_LockYourOwnChargesPhiFeeAndSplitsIt` |
| φ ceiling across gas prices | `testFuzz_PhiFeeNeverExceedsCap` |
| Refund of overpayment | `test_OverpaymentIsRefundedInTransaction` |
| Pull payment, reverting payee | `test_RevertingPayeeCannotBrickTheDoor` |
| Consent required | `test_NobodyCanBeLockedForWithoutConsent` |
| Consent bound to funder | `test_ConsentIsBoundToTheNamedFunder` |
| Relayer carries the exit | `test_AnyRelayerMayCarryTheOpenOrder` |
| Exit is free | `test_OpeningTheDoorIsFree` |
| Exit still respects maturity | `test_OpenDoorStillRespectsMaturity` |
| Nonce replay | `test_SignatureCannotBeReplayed` |
| Deadline expiry | `test_ExpiredSignatureRejected` |
| Cross-chain replay | `test_SignatureFromAnotherChainIsRejected` |
| ERC-1271 contract signer | `test_Erc1271ContractSignerCanOwnAndOpenALock` |
| Free path survives the door | `test_BaseWithdrawIsStillFreeAndUngated` |

**44 tests, 2 suites, all passing** under solc 0.8.24 with `via_ir`.

Gaps are listed honestly in `AUDIT.md` §5.
