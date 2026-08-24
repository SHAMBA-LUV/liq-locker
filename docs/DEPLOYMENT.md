# Deployment — Ethereum mainnet, 2026-08-24

The record is machine-readable in [`deploy/mainnet.json`](../deploy/mainnet.json). This
document is the narrative: what was decided, what it cost, what fought back, and how to
interact with the live contract.

| | |
|---|---|
| **address** | [`0x111111f70cb3469B5285862d7a4e7Cb53d04f502`](https://etherscan.io/address/0x111111f70cb3469B5285862d7a4e7Cb53d04f502#code) |
| tx | [`0x113ba138…f38d`](https://etherscan.io/tx/0x113ba138d140f7ec0ca75c8697d69b7e8a931d508515ded6cee1523c5627f38d) · block 25,822,914 |
| gas | 1,922,491 used at 2.13 gwei ≈ 0.0041 ETH |
| deployer | bankon.eth `0x10f7Ee226B16bea7f365Dc1eDEF159Fc1957D169` |
| `SURPLUS_SINK` | the deployer (immutable, read back on-chain post-deploy) |
| verified | **Pass — Verified** on Etherscan (v0.8.24, optimizer 200, via-IR, **paris**) |
| source rev | `109ea53` — the tree that passed 171 offline + 15 mainnet-fork tests |

## Why the address looks like that

The contract was **not** deployed with plain CREATE. It went through **Create3d**
(`0xa5A2581d564248801cc5e06DbB764c99c170320A`), a CREATE3 factory whose addresses are
`f(factory, deployer, salt)` — independent of bytecode *and* constructor arguments — and
whose salts are **namespaced by `msg.sender`**. Two consequences worth the extra ~91k gas:

1. **One address on every chain.** The same (deployer, salt) reproduces
   `0x111111f7…f502` on any EVM chain, which matters for a token with published
   multichain commitments. The repo compiles for evm **paris** for exactly this reason —
   identical bytecode runs on chains that never adopted shanghai.
2. **Nobody can squat it.** Because salts are sender-namespaced, only the deployer can
   ever claim this address on a chain it hasn't reached yet — the classic CREATE3
   multichain front-running risk is designed out at the factory.

The six leading 1s are mined, not luck: ~40,000 candidate salts were ground through the
factory's address formula (`saltgrinder --target overlord`, which computes pure
`Create3d.addressOf`) and `liq-locker.piscixoq` won. The repunit motif is LUV's own.

**Salt encoding gotcha:** the factory takes `bytes32`. The convention across this stack —
verified against a prior live deployment before trusting it — is
`bytes32 = keccak256(utf8(saltString))`, **not** a right-padded string. Pad the string
instead and you deploy to a different (ugly) address.

## What fought back — feedback for the next deployment

- **`forge verify-contract --show-standard-json-input` (forge 0.3.0) stamps
  `evmVersion: cancun` regardless of `foundry.toml` and ignores `--evm-version`.** The
  deployed bytecode is a paris build, so Etherscan's recompile would not have matched.
  Fix: patch the emitted standard-JSON to `"evmVersion": "paris"` by hand, then prove the
  patched JSON compiles to the exact deployed runtime with local solc **before**
  submitting. It did — byte-for-byte, with only the two immutable `SURPLUS_SINK` slots
  differing from the artifact (as immutables should).
- **Verify via Etherscan V2 REST, not `forge verify`** (forge 0.3.0 speaks the deprecated
  V1). POST `solidity-standard-json-input` to `https://api.etherscan.io/v2/api?chainid=1`,
  and pass every field with `curl --data-urlencode` — plain `-d` mangles the `+` in
  `v0.8.24+commit.e11b9ed9` into a space and the API rejects the compiler version.
- **Constructor args** go in Etherscan's (misspelled) `constructorArguements` field,
  ABI-encoded, without the `0x`.
- **Wallet interaction, hard-won:** touch `window.ethereum` **only on an explicit
  connect click** — any load-time `eth_accounts` or pre-registered `accountsChanged`
  listener races the user's click and kills the wallet dialog. Call
  `window.ethereum.request({method:"eth_requestAccounts"})` directly rather than through
  a library wrapper; reload on `chainChanged`/`accountsChanged`; gate the session on a
  **signed message** (address exposure is not proof of key control); and offer logout via
  `wallet_revokePermissions`.
- The deploy dialog's quoted fee is the EIP-1559 **max-fee ceiling**, roughly 2× what the
  transaction actually costs at send time. Read `effectiveGasPrice` from the receipt
  before drawing conclusions about cost.

## Interacting with the live contract

**Reads need no wallet.** Every view works as an `eth_call` against any public RPC, or
from Etherscan's *Read Contract* tab (the ABI is published with the verified source):
`gates_of(id)`, `time_remaining(id)`, `is_locked(id)`, `total_locked(token)`,
`interest_of(id)`, `surplus(token)`, `lock_count`. One standing warning repeated from the
docs: `locks_of(user)` is **`eth_call` only** — linear gas, never call it from a contract.

**Writes are beneficiary-bound.** `lock_*` from anyone; `extend_*`, `assign`, `withdraw*`,
`redeem_interest`/`collect` only from the lock's current beneficiary; `sweep_surplus` from
anyone (it can only ever reach the immutable sink). There is no owner: no call exists that
pauses, rescues, or shortens anything, from any address, including the deployer's.

**The dapp** in [`dapp/`](../dapp/) ships with the generated ABI
([`dapp/abi.js`](../dapp/abi.js), regenerated from the compiled artifact — never
hand-edited) and is now pinned to the live address in `dapp/app.ts` (`ETHEREUM.locker`).
Reads run against a public RPC with no signer; writes route through the wallet with the
same explicit-consent flow described above. `deploy/autotauribuild.sh` turns it into a
self-contained desktop binary.

**The lock target** is the Uniswap V2 LUV/WETH pair
`0x57D2085Aa859a145cB107845AD03c0eAAFBD8a31` (token0 = LUV `0x2711…8254`, token1 = WETH,
factory = the canonical Uniswap V2 factory — all re-verified on-chain pre-deploy). The
runbook order is unchanged: **dust rehearsal first** (approve 0.001 LP →
`lock_default`), then the full position, then extend as the commitment grows.

## What this changes in PRODUCTION.md

§4's checklist gains its first real-world ticks (deploy, verification); the last box —
**an independent audit** — remains open and remains the gate it always was. The contract
being live does not close it.
