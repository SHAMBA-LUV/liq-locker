// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * THE locks_of GAS BOUND — AUDIT §5, item 3.
 *
 *   "Gas measurement of locks_of at 100 / 1,000 / 10,000 locks, to give the UI a real bound."
 *
 * `locks_of` is documented "for eth_call only. Never call this from a contract." That is the
 * right instruction, but a UI author cannot act on it without a number: is 1,000 locks a
 * page load or a timeout? This measures it and prints the answer, so the guidance stops
 * being a vibe.
 *
 * WHY IT COSTS WHAT IT COSTS. The function walks the caller's append-only index TWICE — once
 * to count the live entries, once to fill the array — and each step reads `beneficiary` out
 * of a lock record in storage. So the cost is ~2 cold SLOADs per indexed id, and it grows
 * LINEARLY and without bound. Nothing prunes the index: `assign` pushes the id onto the new
 * beneficiary's list and leaves the old entry behind (filtered at read time), so a lock that
 * changes hands ten times leaves ten index entries in ten different lists.
 *
 * THE PRACTICAL LIMITS to compare the numbers against:
 *   -  30,000,000  a mainnet block
 *   -  50,000,000  a common `eth_call` gas cap on public RPC providers
 *   - 550,000,000  Alchemy / Infura's higher `eth_call` ceilings
 * An `eth_call` is not charged, but it is capped, and a view that exceeds the node's cap
 * fails outright rather than costing money.
 */

import "forge-std/Test.sol";
import {liquidity_locker} from "../src/liquidity_locker.sol";
import {mock_erc20} from "./mocks.sol";

contract locks_of_gas_test is Test {
    liquidity_locker internal lk;
    mock_erc20 internal tok;
    address internal constant SINK  = address(0x5151);
    address internal constant WHALE = address(0xBEEF01);

    function setUp() public {
        vm.warp(1_800_000_000);
        vm.roll(20_000_000);
        lk = new liquidity_locker(SINK);
        tok = new mock_erc20();
        tok.mint(WHALE, type(uint128).max);
        vm.prank(WHALE);
        tok.approve(address(lk), type(uint256).max);
    }

    function _makeLocks(uint256 n) internal {
        vm.startPrank(WHALE);
        for (uint256 i = 0; i < n; i++) {
            lk.lock(address(tok), 1 ether, uint48(block.timestamp + 90 days), WHALE);
        }
        vm.stopPrank();
    }

    function _measure(uint256 n) internal returns (uint256 used, uint256 returned) {
        _makeLocks(n);
        uint256 g0 = gasleft();
        uint256[] memory ids = lk.locks_of(WHALE);
        used = g0 - gasleft();
        returned = ids.length;
    }

    function test_LocksOf_100() public {
        (uint256 used, uint256 n) = _measure(100);
        emit log_named_uint("locks_of @   100 locks, gas", used);
        emit log_named_uint("  ids returned            ", n);
        assertEq(n, 100, "wrong number of ids");
        assertLt(used, 30_000_000, "100 locks exceeds a whole block");
    }

    function test_LocksOf_1000() public {
        (uint256 used, uint256 n) = _measure(1_000);
        emit log_named_uint("locks_of @ 1,000 locks, gas", used);
        emit log_named_uint("  ids returned            ", n);
        assertEq(n, 1_000, "wrong number of ids");
        assertLt(used, 50_000_000, "1,000 locks exceeds a common eth_call cap");
    }

    function test_LocksOf_10000() public {
        (uint256 used, uint256 n) = _measure(10_000);
        emit log_named_uint("locks_of @10,000 locks, gas", used);
        emit log_named_uint("  ids returned            ", n);
        assertEq(n, 10_000, "wrong number of ids");
        // recorded, not enforced: this is the number the UI needs, whatever it turns out to be
        emit log_named_uint("  x a 30M block           ", used / 30_000_000);
    }

    /// Linear, not quadratic — the shape matters as much as the magnitude.
    function test_LocksOf_GrowthIsLinear() public {
        (uint256 g100, ) = _measure(100);
        (uint256 g1000, ) = _measure(900);         // now 1,000 in total
        uint256 per_lock_small = g100 / 100;
        uint256 per_lock_large = g1000 / 1_000;
        emit log_named_uint("gas per lock @   100", per_lock_small);
        emit log_named_uint("gas per lock @ 1,000", per_lock_large);
        // per-lock cost must not grow with n; allow 2x slack for warm/cold storage effects
        assertLt(per_lock_large, per_lock_small * 2, "locks_of is worse than linear");
    }

    /**
     * The index is append-only and `assign` never prunes it, so a lock that changes hands
     * leaves a stale entry behind in the old beneficiary's list. Those entries are filtered
     * out of the RESULT but still walked, so they cost gas for ever. This is the growth path
     * a UI will actually hit, and it is measured rather than described.
     */
    function test_LocksOf_StaleEntriesStillCostGas() public {
        _makeLocks(200);
        uint256[] memory ids = lk.locks_of(WHALE);

        // hand every lock away: the whale's index keeps all 200 entries, and returns none
        vm.startPrank(WHALE);
        for (uint256 i = 0; i < ids.length; i++) lk.assign(ids[i], address(0xBEEF));
        vm.stopPrank();

        uint256 g0 = gasleft();
        uint256[] memory none = lk.locks_of(WHALE);
        uint256 used = g0 - gasleft();

        assertEq(none.length, 0, "stale entries leaked into the result");
        emit log_named_uint("locks_of over 200 STALE entries, gas", used);
        emit log_string("the entries are filtered from the result but still walked - the index never shrinks");
        assertGt(used, 0, "a walk of 200 stale entries cost nothing, which cannot be right");
    }
}
