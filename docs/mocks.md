# mocks.sol

Test doubles. Each one exists to reproduce a specific class of real token behaviour that
has broken real lockers.

| Mock | Models | Why it matters |
|---|---|---|
| `mock_erc20` | a well-behaved token | the baseline |
| `mock_fee_token` | 5% burned on every transfer | proves credits must be measured deltas |
| `mock_no_return_token` | USDT and descendants — mutates state, returns nothing | a bare interface call reverts in the ABI decoder |
| `mock_false_token` | returns `false` instead of reverting | must be treated as failure, not ignored |
| `mock_reentrant_token` | ERC-777-style callback on transfer out | tries to withdraw the same lock twice |
| `mock_erc1271` | a contract signer accepting exactly one digest | multisigs and smart accounts as beneficiaries |
| `mock_ether_refuser` | reverts on receive | proves fees must be pulled, never pushed |

## `mock_reentrant_token`

Arms once, then on its next `transfer` calls `target.withdraw(attack_id)` and records what
happens. It **reverts with `REENTRY_SUCCEEDED`** if the re-entrant withdrawal succeeds, so
a broken guard fails the test loudly rather than producing a subtly wrong balance.

`test_ReentrantTokenCannotWithdrawTwice` also asserts `evil.reentered()` is true — without
that, a mock that silently failed to fire would make the test pass while proving nothing.

## `mock_erc1271`

Returns the ERC-1271 magic value `0x1626ba7e` for one pre-agreed digest and
`0xffffffff` for everything else. It ignores the signature bytes entirely, which is what
lets the test pass `hex"00"` — the point being that with a contract signer the bytes are
opaque to the verifier and the *contract* decides.
