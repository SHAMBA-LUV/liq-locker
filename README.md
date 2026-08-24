# liq-locker

Ownerless ERC-20 timelocks. Built to hold an AMM pair token and give nobody — including
the deployer — the power to bring maturity forward.

The claim "the liquidity is locked" should be checkable, not believable. That is the
entire product.

## Live on Ethereum mainnet

| | |
|---|---|
| `liquidity_locker` | [**`0x111111f70cb3469B5285862d7a4e7Cb53d04f502`**](https://etherscan.io/address/0x111111f70cb3469B5285862d7a4e7Cb53d04f502#code) — source **verified** on Etherscan |
| deployed | 2026-08-24, [tx `0x113ba138…f38d`](https://etherscan.io/tx/0x113ba138d140f7ec0ca75c8697d69b7e8a931d508515ded6cee1523c5627f38d), via **Create3d** — the same address is reproducible on every EVM chain, by the deployer alone |
| **🔒 the liquidity is LOCKED** | **100% of circulating LUV/WETH LP** — 16,419,484.359707 LP in lock #1 ([tx `0xc2c3c73d…390d`](https://etherscan.io/tx/0xc2c3c73d2bfa216807e900abb17eff4a98808b45768cf11f23e829e52a10390d), block 25,827,873); the treasury's LP balance is **exactly 0**. Matures **2026-11-22T21:57:23Z**, extend-only, no owner to ask |
| public proof | [**luv.pythai.net/liqlock.html**](https://luv.pythai.net/liqlock.html) — live-read by each visitor's own browser; also served from [`dapp/liqlock.html`](dapp/liqlock.html) |
| record · report | [`deploy/mainnet.json`](deploy/mainnet.json) · [`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md) · [`.history/`](.history/) |
| interact | [`dapp/`](dapp/) — generated ABI ([`dapp/abi.js`](dapp/abi.js)), pinned to the live address; reads need no wallet |

The six leading 1s are a mined CREATE3 salt, not luck — and not a different trust story:
the contract has **no owner regardless of who deployed it or how**. The still-open item
from [`PRODUCTION.md`](PRODUCTION.md) §4 is unchanged by going live: **no independent
audit yet**.

## Contracts

| File | License | Purpose |
|---|---|---|
| `src/liquidity_locker.sol` | `Apache-2.0` | the primitive: beneficiary-bound, extend-only, no owner |
| `src/locker_door.sol` | `Apache-2.0` | EIP-712 consent, gasless relay, immutable φ fee |
| `src/in_house.sol` | `Apache-2.0` | zero-dependency ERC-20 helpers and reentrancy guards |
| `src/verifier_ecdsa.sol` | `Apache-2.0` | launch verifier, secp256k1 + ERC-1271 |
| `src/ecdsa_lib.sol` | `Apache-2.0` | EIP-2 low-`s`, canonical `v`, ERC-1271 |
| `src/eip712_lib.sol` | `Apache-2.0` | domain separator with fork protection |
| `src/i_signature_verifier.sol` | `Apache-2.0` | the crypto-agility seam |

The last four are copied verbatim from `../bankon-vault/src/`. Same files, same commit,
no divergence — they are duplicated rather than imported so this module resolves nothing
from outside its own directory.

## Status

Compiles under solc 0.8.24 with `via_ir`. **113 tests, 7 suites, all passing** — including
**6 stateful invariants at 512 runs × 64 calls each (32,768 calls, zero reverts)** — plus a
**mainnet-fork rehearsal** (`make fork-test`, 7 tests) that locks the real Uniswap V2
LUV/WETH pair token held by the real treasury, and proves the liquidity becomes unremovable
while the pool's own reserves are untouched.
Every test is listed with a description and its pass status in [`test.md`](test.md);
`make testmd` re-runs the suite and fails if that file has drifted from reality.
Largest contract is 11,881 bytes runtime, against the 24,576-byte EIP-170 limit.

| Contract | Runtime | Margin |
|---|---|---|
| `locker_door` | 11,881 B | 12,695 B |
| `liquidity_locker` | 8,335 B | 16,241 B |

## Two gates, a ninety-day default, and extension that costs no arithmetic

A lock is bound by **time**, by **block height**, or by **both** — and opens only when the
later of the two has passed. A timestamp is a proposer's claim about the wall clock; block
height is consensus itself, monotone and un-nudgeable. Setting both means the lock cannot be
opened early by a clock and cannot be stranded by a chain that changes cadence.

```solidity
lock_default(token, amount, beneficiary)                    // 90 days — the house default
lock_for(token, amount, duration, beneficiary)              // "a century", not a date
lock_until(token, amount, unlock_at, unlock_block, benef.)  // both gates; either may be 0
lock(token, amount, unlock_at, beneficiary)                 // the absolute form, unchanged

extend_default(id)              // +90 days on top of the CURRENT maturity
extend_by(id, seconds)          // +duration, from maturity — extending late never shortens
extend(id, new_unlock_at)       // absolute, unchanged
extend_block(id, new_block)     // the block gate, extend-only, same rule
extend_block_by(id, blocks)
```

Horizons: **200 years** of time (`MAX_LOCK_DURATION`), **2e9 blocks** (`MAX_LOCK_BLOCKS`) —
~760 years at 12s. A ninety-day lock reaches two centuries a quarter at a time, and every
path is one-way: no gate, on any lock, can ever be brought forward by anyone.

## Quick start

```sh
make test
make sizes
make fork      # dry-run the deploy against mainnet state
```

## What this derives from

SHAMBA LUV's `LUVLocker`, live at `0xe07ACAde4bE2bbc264EA702880ed988EBae9B898`, and the
audit of it dated 2026-08-03 which raised five findings. Three of those findings —
A1 (the owner could extend any depositor's lock), A4 (no incident brake), A5 (single-step
ownership) — are findings *about an owner*. `LUVLockerModern` patched them by constraining
what the owner may do. This module removes the owner instead, so there is nothing left to
constrain. A2 and A3 are fixed directly, in `extend` and in the `beneficiary` argument.

`AUDIT.md` has the finding-by-finding account and the risks that were accepted rather
than fixed.

## The one thing to understand before deploying

**There is no rescue function and no owner.** If you send a token here without locking it,
`sweep_surplus` moves it to `SURPLUS_SINK` — an address fixed at construction that nobody
can change afterwards, including you. Get that constructor argument right. It is the only
address in the contract and there is no second chance at it.

## Two deployments, not one

`make deploy` deploys both the free primitive and the door. They do not share locks:
a lock created through the door lives in the door's storage. This is deliberate. The
free path exists so the fee can never become coercive — if every door function were
unusable tomorrow, `liquidity_locker.withdraw` would still let every beneficiary out.

## Four things to read before deploying

1. `AUDIT.md` — what was inherited broken, what was fixed, what is still accepted risk.
2. `technical.md` §4 — what this does **not** protect against.
3. `usage.md` §3 — the pre-deploy decisions that cannot be changed afterward.
4. `docs/locker_door.md` — why the door takes `bytes` and not `(v, r, s)`.
