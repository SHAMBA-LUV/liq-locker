# test/time_base.sol — TimeBase

`SPDX-License-Identifier: Apache-2.0`

Explicit time cursor for tests. Exists because of AUDIT T-1.

## The problem it solves

With `via_ir = true`, the IR optimizer caches `block.timestamp`. This is legitimate —
`TIMESTAMP` is constant for the duration of a real transaction, so treating it as
loop-invariant is a correct optimization. `vm.warp` changes it out-of-band, which the
optimizer cannot know about.

The consequence, proven in isolation:

```solidity
vm.warp(1_000_000);
vm.warp(block.timestamp + 100);
vm.warp(block.timestamp + 100);
vm.warp(block.timestamp + 100);
assertEq(block.timestamp, 1_000_300);   // FAILS: actual is 1_000_100
```

Three warps of +100 advance the clock by 100 seconds. Any test chaining relative warps is
exercising a different timeline than it appears to — and for a codebase whose entire
subject is multi-month time windows, that silently invalidates the most important tests
in the suite.

## Usage

```solidity
contract MyTest is TimeBase {
    function setUp() public {
        _startClock(1_800_000_000);
    }

    function test_Something() public {
        _advance(365 days);
        _advance(180 days);      // correctly lands at +545 days
    }
}
```

`_advance` tracks time in the state variable `T` and warps to the absolute result, so the
optimizer's cached read is never used for arithmetic.

## Rule for this repository

**Never write `vm.warp(block.timestamp + X)` twice in one test function.** Use
`_advance()`. If you need the current test time, read `T`, not `block.timestamp`.

`_assertClockSane()` is available to assert the cursor and the EVM agree, useful when
debugging a test that mixes raw `vm.warp` with `_advance`.

## Related cheatcode footguns

Two more of the same family were found during the audit (T-2, T-3): both `vm.prank` and
`vm.expectRevert` apply to the *next call*, and arguments evaluate before the outer call.

```solidity
vm.prank(alice);
vault.redeem(vault.balanceOf(alice), ...);   // prank consumed by balanceOf

vm.expectRevert(abi.encodeWithSelector(E.selector, c.foo() + c.bar()));
c.baz();                                      // expectRevert consumed by foo()
```

Hoist every call out of the argument list into a local first.
