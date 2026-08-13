# liquidity_locker.t.sol

25 tests over the ownerless primitive.

## Structure

Locks are created through a `_lock` helper that always pranks as `treasury`, so a test
that cares about *who* is acting says so explicitly rather than inheriting it.

Time is tracked by the absolute cursor in `time_base.sol` (`_startClock`, `_advance`).
**Never write `vm.warp(block.timestamp + X)` here.** With `via_ir` the optimizer caches
`block.timestamp` within a call frame, so chained relative warps silently reuse the first
value — three warps of +100 seconds advance the clock by 100, not 300.

## Groups

| Group | Covers |
|---|---|
| the basics | round trip, maturity enforcement, beneficiary-only exit, double withdraw |
| A1/A2/A3/A4A5 | the four inherited audit findings, one test each |
| fee-on-transfer | measured-delta crediting, and that two lockers can *both* exit |
| non-compliant tokens | USDT-style empty returns, `false`-returning transfers |
| surplus sweep | excludes locked principal; destination immutable; caller gets nothing |
| reentrancy | a token that calls back mid-transfer cannot be paid twice |
| input bounds | past maturity, over-long duration, zero sink, unknown id |
| fuzz | solvency invariant; maturity monotonicity |

## The two tests that failed first

`test_ExtendRespectsMaxDuration` and `test_RejectsBeyondMaxDuration` were written as:

```solidity
vm.expectRevert(...);
L.lock(..., _now() + uint48(L.MAX_LOCK_DURATION()) + 1, ...);
```

`L.MAX_LOCK_DURATION()` is an external staticcall evaluated *after* the cheatcode is
armed, so it consumes `vm.expectRevert` and the assertion silently applies to a call that
was never going to revert. Both **passed vacuously** on the first run and only failed once
the reads were hoisted into locals — the bug surfaced when the tests were made correct,
not before.

Hoist every external read above the cheatcode. The same applies to `vm.prank`.

## The test worth reading first

`test_A4A5_NoPrivilegedPathReachesLockedPrincipal`. It asserts the structural claim the
whole module rests on: the deployer — the most privileged address that exists here — has
no path to a locked token. It is a short test and it is the reason findings A4 and A5 are
marked "not applicable" rather than "fixed".
