# Locker-recognition requests — Dexscreener & GoPlus

Drafts for submitting the liq-locker contract to third-party lock-detection allowlists.
Send from the project's own channels; every claim below is checkable before sending.

---

## 1 · Dexscreener

**Channel:** in-app support chat on dexscreener.com (bottom-left ?), or the contact
attached to Enhanced Token Info orders. Subject line first, body after.

**Subject:** LP lock recognition request — LUV/WETH (Ethereum), LP locked in a verified ownerless locker

Hi Dexscreener team,

The pair https://dexscreener.com/ethereum/0x57d2085aa859a145cb107845ad03c0eaafbd8a31
(LUV/WETH, Uniswap V2, Ethereum) currently shows its liquidity as unlocked. It is locked —
100% of the circulating LP — in a locker contract that isn't on your recognition list yet.
Requesting that the contract be recognized as a liquidity locker:

- Locker: `0x111111f70cb3469B5285862d7a4e7Cb53d04f502`
  (source verified: https://etherscan.io/address/0x111111f70cb3469B5285862d7a4e7Cb53d04f502#code)
- Lock transaction: https://etherscan.io/tx/0xc2c3c73d2bfa216807e900abb17eff4a98808b45768cf11f23e829e52a10390d
  (block 25,827,873 — 16,419,484.359707 LP, the pair's entire circulating supply;
  the previous LP holder's balance is now exactly 0)
- On-chain check, repeatable by anyone:
  `total_locked(0x57D2…8a31)` on the locker == `pair.balanceOf(locker)` == 100% of
  totalSupply minus the burned MINIMUM_LIQUIDITY
- Unlock: 2026-11-22T21:57:23Z (timestamp 1795384643), extend-only

Why this contract can be trusted as a locker, structurally:

- **No owner, no admin, no upgrade path** — no pause, no rescue, no setter, no proxy, no
  `delegatecall`, no `SELFDESTRUCT`. Nobody, including the deployer, can release the LP
  before maturity. This is stronger than typical commercial lockers, which retain owners.
- **Extend-only by construction** — maturities can be lengthened by the beneficiary, never
  shortened by anyone; enforced in code, visible in the verified source.
- Open source + full test record: https://github.com/SHAMBA-LUV/liq-locker
  (186 tests incl. a mainnet-fork rehearsal of this exact position)
- Live public proof page (reads the chain from the visitor's browser):
  https://luv.pythai.net/liqlock.html
- Documentation: https://github.com/SHAMBA-LUV/SHAMBALUV/blob/main/docs/LIQLOCK.md

Happy to provide anything further. Thank you!

Project: SHAMBA LUV — https://luv.pythai.net · token `0x2711111111683B8708cb9a48cBf36a51315F8254` (verified)

---

## 2 · GoPlus Security

**Channel:** https://gopluslabs.io → "Feedback"/appeal form (also: service@gopluslabs.io,
or an issue at github.com/GoPlusSecurity). Their token-security API feeds many screeners,
so recognition here propagates.

**Subject:** Data correction — LP holder `0x111111f7…f502` is a timelock locker, not an EOA/unknown contract (token LUV, Ethereum)

Hello GoPlus team,

Your token security report for `0x2711111111683B8708cb9a48cBf36a51315F8254` (ShambaLuv/LUV,
Ethereum) lists the Uniswap V2 LP holder `0x111111f70cb3469B5285862d7a4e7Cb53d04f502` without
lock recognition. That address is a **liquidity timelock contract** holding 100% of the
circulating LUV/WETH LP, and we'd like it classified as a locker in your LP-holder analysis:

1. Verified source (Etherscan green checkmark):
   https://etherscan.io/address/0x111111f70cb3469B5285862d7a4e7Cb53d04f502#code
   — `liquidity_locker`, solc 0.8.24. Read the source: there is **no owner role at all** —
   no pause, no rescue, no upgrade, no blacklist, no fee switch. Custody is enforced purely
   by two one-way gates (timestamp and block height).
2. The lock: tx `0xc2c3c73d2bfa216807e900abb17eff4a98808b45768cf11f23e829e52a10390d`
   (block 25,827,873). `lock_at(1)` returns the pair token, the beneficiary, amount
   `16419484359707141173121139`, unlock `1795384643` (2026-11-22T21:57:23Z), withdrawn=false.
   `is_locked(1)` returns true. The prior holder's LP balance is 0.
3. Invariant you can verify per-block: `total_locked(pair) == pair.balanceOf(locker)`.
4. Repository with the full test record (186 tests, incl. mainnet-fork):
   https://github.com/SHAMBA-LUV/liq-locker
5. Live proof page (pure eth_call, no wallet): https://luv.pythai.net/liqlock.html
6. Corpus documentation: https://github.com/SHAMBA-LUV/SHAMBALUV/blob/main/docs/LIQLOCK.md

Note: the token itself is fee-on-transfer by design (5% on market trades, split 3:1:1 —
reflection/liquidity/team) — documented at
https://github.com/SHAMBA-LUV/SHAMBALUV/blob/main/docs/REFLECTIONS.md — with no blacklist,
no pause, no mint, and fees changeable downward only; we're aware FoT triggers your generic
flags and simply ask that the facts stand next to them.

Thank you for maintaining the dataset — happy to answer anything.

SHAMBA LUV — https://luv.pythai.net · contact: [operator fills in]

---

**Before sending, re-verify the two claims that could drift:** the treasury's LP balance is
still 0, and `is_locked(1)` is still true. If a re-lock (extend) has occurred, update the
unlock date in both drafts.
