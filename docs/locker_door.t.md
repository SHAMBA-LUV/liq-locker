# locker_door.t.sol

19 tests over the signed door.

## Setup

`holder` is derived from a real private key (`vm.addr(HOLDER_PK)`) because the door's
whole subject is signatures. `vm.txGasPrice(20 gwei)` is set once in `setUp` — without it
`tx.gasprice` is zero and the φ fee is zero, which would make every fee test pass while
asserting nothing.

Signatures are assembled as `abi.encodePacked(r, s, v)` and passed as `bytes`.

## Groups

| Group | Covers |
|---|---|
| the fee | φ split and no stranded wei, underpayment, refunds, pull payment, reverting payee |
| consent | signature required; forged signature rejected; consent bound to the named funder |
| open the door | any relayer may carry it; relayer earns nothing; maturity still enforced |
| replay & expiry | nonce consumption, deadline expiry, cross-chain rejection |
| extend by signature | extend-only holds on the signed path too |
| ERC-1271 | a contract can own and open a lock |
| the free path | base `withdraw` still works with no fee, signature, or relayer |

## Two tests that failed first

`test_Erc1271ContractSignerCanOwnAndOpenALock` and
`test_SignatureFromAnotherChainIsRejected` both computed `deadline = T + 1 hours` and then
advanced a year before submitting. They failed with `signature_expired` while claiming to
test something else entirely — a passing-for-the-wrong-reason hazard in reverse. Deadlines
must be computed in absolute terms against the cursor's *final* position.

## The test worth reading first

`test_Erc1271ContractSignerCanOwnAndOpenALock`. It is the single test that a `(v, r, s)`
door could not be made to pass, and it is the argument for the change: a contract cannot
produce a secp256k1 signature, so a `(v, r, s)` door excludes every multisig, smart
account, and EIP-7702 delegated EOA from ever being a beneficiary. `bankon.eth` is exactly
such an account.

Runner-up: `test_BaseWithdrawIsStillFreeAndUngated`, which pins the property that keeps
the fee non-coercive — if every door function broke tomorrow, every beneficiary could
still get out.
