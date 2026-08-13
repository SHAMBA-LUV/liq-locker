# in_house.sol

Zero-dependency primitives: `i_erc20_min`, `safe_token`, `guarded`.

`Apache-2.0` · library and abstract contract, no standalone deployment

---

## Why this file exists instead of an import

A lock intended to hold liquidity for a decade should not inherit a supply chain. This
module resolves nothing from npm, nothing from a package registry, and nothing from a
network that may or may not exist when someone next needs to verify the source. The code
involved is sixty lines. `forge-std` appears only under `test/`.

Derived from SHAMBA LUV's `base/InHouse.sol`, which made the same call for the same reason.

## `i_erc20_min`

`balanceOf`, `transfer`, `transferFrom`. Deliberately not a full `IERC20` — the locker
needs three functions and declaring more would invite calling them.

## `safe_token`

`safe_transfer` and `safe_transfer_from`, handling the tokens people actually deploy.

USDT and its many descendants return **nothing** from `transfer`/`transferFrom`. A bare
interface call against those reverts inside the ABI decoder, which demands a 32-byte
return value. These helpers treat:

| Return | Meaning |
|---|---|
| revert | failure |
| no return data | **success** |
| `false` | failure |
| `true` | success |

which is the only reading consistent with both the standard and reality. Tested against
both cases: `test_UsdtStyleNoReturnDataTokenWorks` and
`test_TokenReturningFalseIsTreatedAsFailure`.

Note these do **not** wrap `approve`. Neither locker ever approves anything — tokens are
pulled in with `transferFrom` and pushed out with `transfer`, so there is no standing
allowance anywhere and none of USDT's non-zero-to-non-zero approval hazard applies.

## `guarded`

Two modifiers over a single `uint256` 1/2 flag.

**`non_reentrant`** — on every mutator.

**`when_not_entered`** — on every view. Without it, an integrator reading `total_locked`
or `lock_at` from inside a token callback would be handed state caught between effects.
Read-only reentrancy is the failure mode that does not show up in the guarded contract at
all; it shows up in whoever trusted its views. Carried forward from the LUVLocker audit,
which verified it as a property worth keeping.

**Not `TSTORE`/`TLOAD`.** `evm_version = "paris"`. Transient storage is cheaper and newer;
for contracts meant to outlive several EVM upgrades, take the ~5,000 gas and keep the
certainty. Same reasoning as bankon-vault, and the same deliberate reversal of the usual
gas-optimisation advice.
