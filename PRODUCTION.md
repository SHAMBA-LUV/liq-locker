# liq-locker — production deployment

**Status: engineering-complete, not independently audited.** Every test the audit asked for
is written and passing. The one remaining item, an independent review, cannot be produced
from inside this repository and is not a box the authors get to tick. Read §5 before
deciding.

Verified 2026-08-13 · solc 0.8.24 · optimizer 200 · via-ir on · evm **paris**

---

## 1. What ships

| contract | runtime | ctor | what it is |
|---|---|---|---|
| `liquidity_locker` | **8,335 B** | `(surplus_sink)` | the vault. Beneficiary-bound, extend-only, no owner |
| `locker_door` | **11,881 B** | `(surplus_sink, overlord, overseer, verifier)` | signed-consent front door; locks made through it live in **its** storage |
| `VerifierECDSA` | **849 B** | `()` | secp256k1 signature check, permanently |

All three are far under the 24,576-byte limit — margins 16,241 / 12,695 / 23,727.

**You do not have to deploy all three.** For an LP lock, `liquidity_locker` alone is the
whole product; the door exists for signed/relayed flows and brings a trust assumption the
bare locker does not have (§5).

## 2. The test record

| suite | tests | notes |
|---|---|---|
| default profile | **171** | hermetic, offline, `forge test` |
| mainnet fork | **7** | `make fork-test`, against the real LUV/WETH pair at HEAD |
| **total** | **178** | 0 failing |

Of those, the depth that matters:

- **6 stateful invariants** at 512 runs × 64 calls = **32,768 calls, zero reverts** — including
  ghost-recorded proofs that no gate ever moved backwards and no withdrawal ever happened
  early, checked against state captured at call time rather than re-derived from the contract.
- **28 adversarial gate attacks** — boundary in both directions on both gates, proposer drift
  1–900s, one-gate-passed, extension abuse, authority, succession, re-entrancy, overflow.
- **32,776 differential signature comparisons** against OpenZeppelin's ECDSA.
- **Mutation-tested**: removing the block gate and mis-basing `extend_by` are both caught.
- A **mainnet-fork rehearsal** that locks the real Uniswap V2 LUV/WETH position, confirms the
  treasury's LP goes to zero, confirms `pair.burn()` then reverts, and confirms the pool's
  own reserves are unchanged — locking LP moves the claim, never the liquidity.

Reproduce:

```
forge test && make fork-test
```

## 3. Deploy

```bash
# 1. the vault alone — this is all an LP lock needs
forge create src/liquidity_locker.sol:liquidity_locker \
  --constructor-args $SURPLUS_SINK \
  --rpc-url mainnet --verify

# 2. only if you want the signed-consent door
forge create src/verifier_ecdsa.sol:VerifierECDSA --rpc-url mainnet --verify
forge create src/locker_door.sol:locker_door \
  --constructor-args $SURPLUS_SINK $OVERLORD $OVERSEER $VERIFIER \
  --rpc-url mainnet --verify
```

`SURPLUS_SINK` is immutable and receives only tokens no lock claims. It can never reach
locked principal — that is arithmetic, not a permission, and `sweep_surplus` is
permissionless precisely because it cannot choose a destination or an amount.

## 4. Before the real position

- [x] `make sizes` — every contract under 24,576 B
- [x] Rehearsal proven in CI against the real pair (`test_Fork_RehearsalDustLockClearsEndToEnd`)
- [ ] `SURPLUS_SINK` verified on a testnet by actually sweeping to it
- [ ] Beneficiary is a contract you control or a key you can still sign with **at maturity** —
      locks outlive the wallets people expect them to
- [ ] Verifier choice made deliberately (skip if deploying the bare locker) — **see §5**
- [ ] Dust rehearsal end to end, on mainnet, before the real position
- [ ] Maturity diarized at T−30d and T−7d, with the re-lock plan published *before* it
- [ ] **Independent audit**

The first six are yours to do. The last one is the gate.

## 5. What you are trusting, stated plainly

**No owner, anywhere.** No pause, no rescue, no setter, no proxy, no `delegatecall`, no
`SELFDESTRUCT`, no `tx.origin`. Nobody — including whoever deploys it — can bring a maturity
forward. That is the product; everything else is detail.

**Two gates, and the later governs.** Time is what people commit in; block height is
consensus and cannot be nudged by a proposer. A lock setting both cannot be opened early by
a clock and cannot be stranded by a chain that changes cadence. Both directions are proven.

**The door's verifier is the whole trust boundary.** `locker_door` asks an immutable
`ISignatureVerifier` whether a signature is good. A hostile verifier forges consent
completely — `test/malicious_verifier.t.sol` demonstrates an attacker withdrawing a victim's
matured lock to themselves with a **zero-byte signature**. Two things bound it: the damage
cannot reach a lock made directly against `liquidity_locker`, and a forged instruction still
waits for the gates. But it means:

> **Verifying `locker_door` on Etherscan is not sufficient.** Read `VERIFIER()` and verify
> that contract too. If you deploy the bare locker, this paragraph does not apply to you.

**Extension is one-way, and that is irreversible.** `extend_by` adds to current maturity, not
to `now`. There is no shortening path anywhere, by anyone. Extend deliberately.

**`locks_of` is an `eth_call` view.** Never call it from a contract. Linear at ~1,950 gas per
indexed entry — 21.6M at 10,000 locks. The index is append-only: an assigned-away lock still
costs gas for ever.

## 6. What this document does not claim

It does not claim the contracts are safe. It claims that a specific, listed set of properties
was tested, by the people who wrote them, and that those tests pass. The value of an
independent audit is exactly that it is not this document — and the sibling repo is the
argument for paying for one: `luv-locker`'s stateful fuzzer, added the same day as this work,
found a real solvency bug (D-1) that four earlier test files had missed.

Nothing here has been deployed. No transaction has been sent.
