// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.0;

import "forge-std/Test.sol";

/**
 * @title  TimeBase
 * @notice Explicit time cursor for tests.
 * @dev    AUDIT T-1. With `via_ir = true` the IR optimizer treats `block.timestamp` as
 *         loop-invariant within a call frame and caches it, because TIMESTAMP genuinely
 *         is constant for the duration of a real transaction. `vm.warp` changes it
 *         out-of-band, which the optimizer cannot know.
 *
 *         The consequence: chained `vm.warp(block.timestamp + X)` calls in one test
 *         function silently reuse the FIRST observed timestamp. Three warps of +100
 *         seconds advance the clock by 100 seconds, not 300. Tests written that way do
 *         not test the timeline they appear to.
 *
 *         Every test in this repository therefore tracks time in a state variable and
 *         warps to absolute values. Never write `vm.warp(block.timestamp + X)` twice in
 *         one function here.
 */
abstract contract TimeBase is Test {
    uint256 internal T;

    function _startClock(uint256 ts) internal {
        T = ts;
        vm.warp(T);
    }

    /// @notice Advance the cursor and warp to the absolute result.
    function _advance(uint256 secs) internal {
        T += secs;
        vm.warp(T);
    }

    /// @notice Sanity check that the cursor and the EVM agree.
    function _assertClockSane() internal view {
        require(block.timestamp == T, "TIME_CURSOR_DESYNC");
    }
}
