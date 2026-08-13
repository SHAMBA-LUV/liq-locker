// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.0;

import "forge-std/Test.sol";
import {TimeBase} from "./time_base.sol";
import {liquidity_locker} from "../src/liquidity_locker.sol";
import {mock_erc20} from "./mocks.sol";

/**
 * LOCKING ACROSS TIME.
 *
 * The other time suite checks maturity to the second. This one checks what happens over the
 * spans this vault claims to serve: decades, a century, two centuries, and the drift between
 * the two gates as a chain's cadence changes underneath a lock that was set once and left.
 *
 * The properties that only appear at length:
 *   • maturity is exact at 1, 10, 50, 100 and 200 years, not merely "eventually"
 *   • the horizon is a bound on REMAINING duration, so it moves with now — a lock can be
 *     carried past two centuries by extending as time passes, and never by jumping the cap
 *   • extension repeated across real elapsed time is monotone, every single step
 *   • if blocks SLOW, the block gate becomes the binding one; if they SPEED UP, the clock
 *     stays binding — the pair of gates is what makes a long lock cadence-proof
 *   • a stalled chain does not open a block-gated lock, however long the clock runs
 *   • interest earned across years splits pro-rata, and a lock that sat for a century
 *     collects what it was owed
 *   • custody can pass through generations without the maturity moving
 *
 * AUDIT T-1: every advance goes through the absolute cursors (T for time, B for blocks).
 * Never chain vm.warp(block.timestamp + X) under via_ir.
 */
contract liquidity_locker_across_time_test is TimeBase {
    liquidity_locker internal L;
    mock_erc20 internal lp;

    address internal treasury = address(0xA11CE);
    address internal heir = address(0xDA0);
    address internal grandheir = address(0x6E4);
    address internal other = address(0xB0B);
    address internal sink = address(0x5142);

    uint256 internal B;

    uint256 internal constant YEAR = 365 days;
    uint256 internal constant DECADE = 3652 days + 12 hours; // 10 years, leap-corrected
    uint256 internal constant CENTURY = 36525 days;

    function setUp() public {
        _startClock(1_800_000_000);
        B = 21_000_000;
        vm.roll(B);
        L = new liquidity_locker(sink);
        lp = new mock_erc20();
        lp.mint(treasury, 10_000_000 ether);
        lp.mint(other, 10_000_000 ether);
        vm.prank(treasury);
        lp.approve(address(L), type(uint256).max);
        vm.prank(other);
        lp.approve(address(L), type(uint256).max);
    }

    function _roll(uint256 blocks_) internal {
        B += blocks_;
        vm.roll(B);
    }

    function _lockFor(uint256 amount, uint256 duration, address beneficiary) internal returns (uint256 id) {
        vm.prank(treasury);
        id = L.lock_for(address(lp), amount, duration, beneficiary);
    }

    // ───────────────── maturity is exact at every span ─────────────────

    /// One second short is still locked, at one year and at two hundred.
    function test_MaturityIsExactAtEverySpan() public {
        uint256[5] memory spans = [YEAR, DECADE, 50 * YEAR, CENTURY, L.MAX_LOCK_DURATION()];
        for (uint256 i; i < spans.length; i++) {
            // a fresh clock per span, so each is measured from its own start
            _startClock(1_800_000_000);
            uint256 id = _lockFor(1_000 ether, spans[i], address(0));

            _advance(spans[i] - 1);
            vm.prank(treasury);
            vm.expectRevert(liquidity_locker.still_locked.selector);
            L.withdraw(id);

            _advance(1);
            vm.prank(treasury);
            L.withdraw(id);
        }
        assertEq(lp.balanceOf(treasury), 10_000_000 ether, "every span returned its principal");
    }

    // ───────────────── the horizon moves with now ─────────────────

    /**
     * The cap bounds how far ahead of NOW a lock may reach, not how long it may live. So a
     * lock can outlive the horizon by being extended as time passes — which is the whole
     * reason extension exists — while no single call can ever jump past it.
     */
    function test_TheHorizonMovesWithNowSoALockCanOutliveIt() public {
        uint256 max = L.MAX_LOCK_DURATION();
        uint256 id = _lockFor(1_000 ether, max, address(0)); // two centuries, the limit today
        uint256 start = T;

        // not one second more, right now
        vm.prank(treasury);
        vm.expectRevert(liquidity_locker.duration_too_long.selector);
        L.extend_by(id, 1);

        _advance(CENTURY); // a hundred years pass…
        vm.prank(treasury);
        L.extend_by(id, CENTURY); // …and now another century is inside the horizon

        (uint48 at,) = L.gates_of(id);
        assertEq(uint256(at), start + max + CENTURY);
        assertGt(uint256(at) - start, 2 * CENTURY, "the lock now outlives the horizon it started under");
        assertTrue(L.is_locked(id));
    }

    /// Extending across time is monotone at every step, for a decade of quarterly pushes.
    function test_QuarterlyExtensionAcrossADecadeIsMonotone() public {
        uint256 id = _lockFor(1_000 ether, 90 days, address(0));
        (uint48 prev,) = L.gates_of(id);
        for (uint256 q; q < 40; q++) {
            _advance(90 days); // a real quarter passes between each extension
            vm.prank(treasury);
            L.extend_default(id);
            (uint48 next,) = L.gates_of(id);
            assertGt(next, prev, "an extension failed to move maturity forward");
            prev = next;
        }
        assertTrue(L.is_locked(id), "still locked after a decade of quarters");
    }

    // ───────────────── cadence drift: why there are two gates ─────────────────

    /**
     * A lock set today assumes today's cadence. If blocks SLOW DOWN, the block gate arrives
     * later than the clock did — and the lock stays shut until consensus catches up, which
     * is the conservative direction and the one you want for a liquidity lock.
     */
    function test_WhenBlocksSlowDownTheBlockGateBecomesBinding() public {
        uint256 blocksAtTwelve = YEAR / 12;
        vm.prank(treasury);
        uint256 id = L.lock_until(
            address(lp), 1_000 ether, uint48(T + YEAR), uint40(B + blocksAtTwelve), address(0)
        );

        // a year passes, but the chain only produced blocks at a 15s cadence
        _advance(YEAR);
        _roll(YEAR / 15);
        (uint256 secs, uint256 blks) = L.time_remaining(id);
        assertEq(secs, 0, "the clock has arrived");
        assertGt(blks, 0, "consensus has not");
        vm.prank(treasury);
        vm.expectRevert(liquidity_locker.still_locked.selector);
        L.withdraw(id);

        _roll(blks); // the missing blocks finally arrive
        vm.prank(treasury);
        L.withdraw(id);
    }

    /**
     * And if blocks SPEED UP, the block gate arrives early — the clock is still binding, so
     * a faster chain cannot shorten a lock that was written in years.
     */
    function test_WhenBlocksSpeedUpTheClockRemainsBinding() public {
        uint256 blocksAtTwelve = YEAR / 12;
        vm.prank(treasury);
        uint256 id = L.lock_until(
            address(lp), 1_000 ether, uint48(T + YEAR), uint40(B + blocksAtTwelve), address(0)
        );

        _roll(blocksAtTwelve * 2); // twice the blocks, in half the time
        _advance(YEAR / 2);
        (uint256 secs, uint256 blks) = L.time_remaining(id);
        assertEq(blks, 0, "consensus has arrived");
        assertGt(secs, 0, "the clock has not");
        vm.prank(treasury);
        vm.expectRevert(liquidity_locker.still_locked.selector);
        L.withdraw(id);

        _advance(YEAR / 2);
        vm.prank(treasury);
        L.withdraw(id);
    }

    /// A halted chain is the limit case of slow blocks: time alone never opens a block gate.
    function test_AStalledChainKeepsABlockGatedLockShut() public {
        vm.prank(treasury);
        uint256 id = L.lock_until(address(lp), 1_000 ether, 0, uint40(B + 1_000), address(0));

        _advance(CENTURY); // a hundred years of clock, not one block
        vm.prank(treasury);
        vm.expectRevert(liquidity_locker.still_locked.selector);
        L.withdraw(id);
        assertTrue(L.is_locked(id), "a stalled chain must not open a lock");

        _roll(1_000);
        vm.prank(treasury);
        L.withdraw(id);
    }

    // ───────────────── value earned across years ─────────────────

    /**
     * Two locks, unequal, held while the token reflects repeatedly over years. Each collects
     * its own share, whenever it asks, and the vault never pays out more than arrived.
     */
    function test_InterestSplitsProRataAcrossYearsOfReflections() public {
        uint256 idA = _lockFor(1_000 ether, 10 * YEAR, address(0)); // treasury, 1x
        vm.prank(other);
        uint256 idB = L.lock_for(address(lp), 3_000 ether, 10 * YEAR, address(0)); // other, 3x

        uint256 reflected;
        for (uint256 y; y < 10; y++) {
            _advance(YEAR);
            lp.mint(address(L), 400 ether); // a year's reflections arrive
            reflected += 400 ether;
        }

        uint256 aBefore = lp.balanceOf(treasury);
        uint256 bBefore = lp.balanceOf(other);
        vm.prank(treasury);
        uint256 paidA = L.collect(idA);
        vm.prank(other);
        uint256 paidB = L.collect(idB);

        assertApproxEqAbs(paidA, reflected / 4, 1e6, "1x share is off");
        assertApproxEqAbs(paidB, (reflected * 3) / 4, 1e6, "3x share is off");
        assertLe(paidA + paidB, reflected, "paid out more than ever arrived");
        assertEq(lp.balanceOf(treasury) - aBefore, paidA);
        assertEq(lp.balanceOf(other) - bBefore, paidB);

        // principal is untouched by a decade of collecting
        assertEq(L.total_locked(address(lp)), 4_000 ether);
    }

    /// A lock left alone for a century still collects what it was owed, in one call at the end.
    function test_ACenturyOfReflectionsIsStillCollectableAtTheEnd() public {
        uint256 id = _lockFor(1_000 ether, CENTURY, address(0));
        uint256 reflected;
        for (uint256 d; d < 10; d++) {
            _advance(CENTURY / 10);
            lp.mint(address(L), 100 ether);
            reflected += 100 ether;
        }
        assertApproxEqAbs(L.interest_of(id), reflected, 1e6, "a century of interest went missing");

        vm.prank(treasury);
        L.withdraw(id); // principal AND the accrued interest, in one exit
        assertApproxEqAbs(lp.balanceOf(treasury), 10_000_000 ether + reflected, 1e6);
    }

    // ───────────────── custody across generations ─────────────────

    function test_CustodyPassesThroughGenerationsWithoutMovingMaturity() public {
        uint256 id = _lockFor(1_000 ether, CENTURY, address(0));
        (uint48 at0,) = L.gates_of(id);

        _advance(30 * YEAR);
        vm.prank(treasury);
        L.assign(id, heir);

        _advance(30 * YEAR);
        vm.prank(heir);
        L.assign(id, grandheir);

        (uint48 at1,) = L.gates_of(id);
        assertEq(at1, at0, "succession moved the maturity");

        // the previous holders are strangers to it now
        vm.prank(heir);
        vm.expectRevert(liquidity_locker.not_beneficiary.selector);
        L.withdraw(id);

        _advance(CENTURY - 60 * YEAR);
        vm.prank(grandheir);
        L.withdraw(id);
        assertEq(lp.balanceOf(grandheir), 1_000 ether, "a century later, to the third holder");
    }

    // ───────────────── the countdown tells the truth the whole way ─────────────────

    function test_TimeRemainingCountsDownTruthfullyAcrossACentury() public {
        uint256 id = _lockFor(1_000 ether, CENTURY, address(0));
        uint256 start = T;
        for (uint256 i = 1; i <= 10; i++) {
            _advance(CENTURY / 10);
            (uint256 secs,) = L.time_remaining(id);
            uint256 expected = (start + CENTURY) - T;
            assertEq(secs, expected, "the countdown drifted from the clock");
        }
        (uint256 last,) = L.time_remaining(id);
        assertEq(last, 0, "matured, and the countdown says so");
        assertFalse(L.is_locked(id));
    }
}
