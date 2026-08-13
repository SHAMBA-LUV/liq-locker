// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.0;

import "forge-std/Test.sol";
import {TimeBase} from "./time_base.sol";
import {liquidity_locker} from "../src/liquidity_locker.sol";
import {mock_erc20} from "./mocks.sol";

/**
 * The two gates, the ninety-day default, and easy extension.
 *
 * A lock here may be bound by TIME, by BLOCK HEIGHT, or by both, and opens only when the
 * later of the two has passed. Time is what a commitment is written in; block height is
 * consensus itself, monotone and un-nudgeable by a proposer. This suite holds both to the
 * same one-way rule the time gate always had — a lock may be lengthened by its beneficiary
 * and by nobody else, and can never be shortened by anyone, including by extending it late.
 *
 * AUDIT T-1: time moves through the absolute cursor in TimeBase, never chained warps.
 * Block height moves with vm.roll to an absolute target for the same reason.
 */
contract liquidity_locker_gates_test is TimeBase {
    liquidity_locker internal L;
    mock_erc20 internal lp;

    address internal treasury = address(0xA11CE);
    address internal dao = address(0xDA0);
    address internal stranger = address(0xBAD);
    address internal sink = address(0x5142);

    uint256 internal B; // the block cursor, absolute like T

    uint256 internal constant DAY = 1 days;
    uint256 internal constant QUARTER = 90 days;
    uint256 internal constant YEAR = 365 days;
    uint256 internal constant CENTURY = 36525 days; // 100 years, leap-corrected

    function setUp() public {
        _startClock(1_800_000_000);
        B = 21_000_000; // a plausible mainnet height
        vm.roll(B);
        L = new liquidity_locker(sink);
        lp = new mock_erc20();
        lp.mint(treasury, 1_000_000 ether);
        vm.prank(treasury);
        lp.approve(address(L), type(uint256).max);
    }

    function _roll(uint256 blocks_) internal {
        B += blocks_;
        vm.roll(B);
    }

    function _lockDefault(uint256 amount) internal returns (uint256 id) {
        vm.prank(treasury);
        id = L.lock_default(address(lp), amount, address(0));
    }

    // ───────────────────────── the ninety-day default ─────────────────────────

    function test_TheDefaultIsNinetyDays() public view {
        assertEq(L.DEFAULT_LOCK_DURATION(), 90 days);
    }

    function test_LockDefaultMaturesAtNinetyDaysToTheSecond() public {
        uint256 id = _lockDefault(1_000 ether);
        (uint48 at, uint40 blk) = L.gates_of(id);
        assertEq(at, uint48(T + QUARTER));
        assertEq(blk, 0, "the default sets no block gate");

        _advance(QUARTER - 1);
        vm.prank(treasury);
        vm.expectRevert(liquidity_locker.still_locked.selector);
        L.withdraw(id);

        _advance(1); // exactly ninety days
        vm.prank(treasury);
        L.withdraw(id);
        assertEq(lp.balanceOf(treasury), 1_000_000 ether);
    }

    function test_LockForTakesADurationNotADate() public {
        vm.prank(treasury);
        uint256 id = L.lock_for(address(lp), 1_000 ether, CENTURY, dao);
        (uint48 at,) = L.gates_of(id);
        assertEq(at, uint48(T + CENTURY), "a century, expressed as a century");
        assertTrue(L.is_locked(id));
    }

    function test_LockForRejectsZeroAndBeyondTheHorizon() public {
        vm.prank(treasury);
        vm.expectRevert(liquidity_locker.bad_unlock_time.selector);
        L.lock_for(address(lp), 1_000 ether, 0, address(0));

        uint256 max = L.MAX_LOCK_DURATION();
        vm.prank(treasury);
        vm.expectRevert(liquidity_locker.duration_too_long.selector);
        L.lock_for(address(lp), 1_000 ether, max + 1, address(0));

        vm.prank(treasury); // the horizon itself is allowed — two hundred years
        uint256 id = L.lock_for(address(lp), 1_000 ether, max, address(0));
        (uint48 at,) = L.gates_of(id);
        assertEq(at, uint48(T + max));
    }

    // ───────────────────────── easy extension ─────────────────────────

    function test_ExtendDefaultAddsAQuarterToTheCurrentMaturity() public {
        uint256 id = _lockDefault(1_000 ether);
        vm.prank(treasury);
        L.extend_default(id);
        (uint48 at,) = L.gates_of(id);
        assertEq(at, uint48(T + 2 * QUARTER), "quarters accumulate");
    }

    /// A ninety-day lock becomes a two-century one, a quarter at a time, with no arithmetic.
    function test_QuartersCompoundIntoCenturies() public {
        uint256 id = _lockDefault(1_000 ether);
        uint256 expected = T + QUARTER;
        for (uint256 i = 0; i < 40; i++) {
            vm.prank(treasury);
            L.extend_default(id);
            expected += QUARTER;
        }
        (uint48 at,) = L.gates_of(id);
        assertEq(at, uint48(expected));
        assertGt(uint256(at) - T, 10 * YEAR, "past the decade the old design capped at");
    }

    function test_ExtendByAddsToMaturityNotToNow() public {
        uint256 id = _lockDefault(1_000 ether);
        uint256 maturity = T + QUARTER;
        _advance(30 days); // extending LATE must not shorten the lock
        vm.prank(treasury);
        L.extend_by(id, YEAR);
        (uint48 at,) = L.gates_of(id);
        assertEq(at, uint48(maturity + YEAR), "measured from maturity, never from now");
    }

    function test_ExtendByZeroReverts() public {
        uint256 id = _lockDefault(1_000 ether);
        vm.prank(treasury);
        vm.expectRevert(liquidity_locker.not_shortenable.selector);
        L.extend_by(id, 0);
    }

    function test_ExtendByRespectsTheHorizon() public {
        uint256 id = _lockDefault(1_000 ether);
        // AUDIT T-2: hoist the external read. Left inline it consumes both the prank and
        // the expectRevert, and the test passes vacuously — the exact mistake this
        // repository has made before.
        uint256 max = L.MAX_LOCK_DURATION();
        vm.prank(treasury);
        vm.expectRevert(liquidity_locker.duration_too_long.selector);
        L.extend_by(id, max); // maturity is already 90 days out, so max more is over the horizon
    }

    function test_OnlyTheBeneficiaryMayExtend() public {
        vm.prank(treasury);
        uint256 id = L.lock_default(address(lp), 1_000 ether, dao);
        vm.prank(stranger);
        vm.expectRevert(liquidity_locker.not_beneficiary.selector);
        L.extend_default(id);
        vm.prank(treasury); // not even the funder, once it is the dao's lock
        vm.expectRevert(liquidity_locker.not_beneficiary.selector);
        L.extend_by(id, YEAR);
    }

    // ───────────────────────── the block gate ─────────────────────────

    function test_BlockGateHoldsAfterTheTimeGateOpens() public {
        vm.prank(treasury);
        uint256 id = L.lock_until(address(lp), 1_000 ether, uint48(T + DAY), uint40(B + 10_000), address(0));

        _advance(DAY); // time has matured…
        _roll(9_999); // …but the chain has not reached the block
        vm.prank(treasury);
        vm.expectRevert(liquidity_locker.still_locked.selector);
        L.withdraw(id);
        assertTrue(L.is_locked(id), "still locked while either gate holds");

        _roll(1);
        vm.prank(treasury);
        L.withdraw(id);
    }

    function test_TimeGateHoldsAfterTheBlockGateOpens() public {
        vm.prank(treasury);
        uint256 id = L.lock_until(address(lp), 1_000 ether, uint48(T + YEAR), uint40(B + 10), address(0));

        _roll(10); // blocks have passed…
        vm.prank(treasury);
        vm.expectRevert(liquidity_locker.still_locked.selector); // …the clock has not
        L.withdraw(id);

        _advance(YEAR);
        vm.prank(treasury);
        L.withdraw(id);
    }

    function test_BlockOnlyLockNeedsNoTimestamp() public {
        vm.prank(treasury);
        uint256 id = L.lock_until(address(lp), 1_000 ether, 0, uint40(B + 100), address(0));
        (uint48 at, uint40 blk) = L.gates_of(id);
        assertEq(at, 0);
        assertEq(blk, uint40(B + 100));

        _advance(10 * YEAR); // all the time in the world does not open it
        vm.prank(treasury);
        vm.expectRevert(liquidity_locker.still_locked.selector);
        L.withdraw(id);

        _roll(100);
        vm.prank(treasury);
        L.withdraw(id);
    }

    function test_ALockWithNoGateAtAllIsRejected() public {
        vm.prank(treasury);
        vm.expectRevert(liquidity_locker.bad_unlock_time.selector);
        L.lock_until(address(lp), 1_000 ether, 0, 0, address(0));
    }

    function test_GatesInThePastAreRejected() public {
        vm.prank(treasury);
        vm.expectRevert(liquidity_locker.bad_unlock_time.selector);
        L.lock_until(address(lp), 1_000 ether, uint48(T), uint40(B + 10), address(0)); // now is not the future

        vm.prank(treasury);
        vm.expectRevert(liquidity_locker.bad_unlock_time.selector);
        L.lock_until(address(lp), 1_000 ether, uint48(T + DAY), uint40(B), address(0));
    }

    function test_BlockGateRespectsItsHorizon() public {
        uint256 maxb = L.MAX_LOCK_BLOCKS();
        vm.prank(treasury);
        vm.expectRevert(liquidity_locker.duration_too_long.selector);
        L.lock_until(address(lp), 1_000 ether, 0, uint40(B + maxb + 1), address(0));

        vm.prank(treasury);
        uint256 id = L.lock_until(address(lp), 1_000 ether, 0, uint40(B + maxb), address(0));
        (, uint40 blk) = L.gates_of(id);
        assertEq(blk, uint40(B + maxb));
    }

    // ── the block gate is extend-only, exactly like the time gate ──

    function test_BlockGateExtendsAndNeverShortens() public {
        vm.prank(treasury);
        uint256 id = L.lock_until(address(lp), 1_000 ether, uint48(T + DAY), uint40(B + 1_000), address(0));

        vm.prank(treasury);
        L.extend_block(id, uint40(B + 5_000));
        (, uint40 blk) = L.gates_of(id);
        assertEq(blk, uint40(B + 5_000));

        vm.prank(treasury); // one block earlier is still shortening
        vm.expectRevert(liquidity_locker.not_shortenable.selector);
        L.extend_block(id, uint40(B + 4_999));

        vm.prank(treasury); // and so is the same block
        vm.expectRevert(liquidity_locker.not_shortenable.selector);
        L.extend_block(id, uint40(B + 5_000));
    }

    function test_BlockGateCanBeAddedToATimeOnlyLock() public {
        uint256 id = _lockDefault(1_000 ether);
        (, uint40 before_) = L.gates_of(id);
        assertEq(before_, 0);

        vm.prank(treasury);
        L.extend_block_by(id, 50_000);
        (, uint40 after_) = L.gates_of(id);
        assertEq(after_, uint40(B + 50_000), "measured from the current height when unset");

        // and now the block gate outlives the time gate
        _advance(QUARTER);
        vm.prank(treasury);
        vm.expectRevert(liquidity_locker.still_locked.selector);
        L.withdraw(id);
    }

    function test_ExtendBlockByAddsToTheGateNotToTheHeight() public {
        vm.prank(treasury);
        uint256 id = L.lock_until(address(lp), 1_000 ether, uint48(T + DAY), uint40(B + 1_000), address(0));
        _roll(500); // extending late must not shorten
        vm.prank(treasury);
        L.extend_block_by(id, 2_000);
        (, uint40 blk) = L.gates_of(id);
        assertEq(blk, uint40(21_000_000 + 1_000 + 2_000));
    }

    function test_OnlyTheBeneficiaryMayExtendTheBlockGate() public {
        vm.prank(treasury);
        uint256 id = L.lock_until(address(lp), 1_000 ether, uint48(T + DAY), uint40(B + 100), dao);
        vm.prank(stranger);
        vm.expectRevert(liquidity_locker.not_beneficiary.selector);
        L.extend_block(id, uint40(B + 200));
        vm.prank(treasury);
        vm.expectRevert(liquidity_locker.not_beneficiary.selector);
        L.extend_block_by(id, 200);
    }

    function test_ABlockGateInThePastIsRejectedOnExtend() public {
        vm.prank(treasury);
        uint256 id = L.lock_until(address(lp), 1_000 ether, uint48(T + YEAR), uint40(B + 10), address(0));
        _roll(100); // the gate is now behind us
        vm.prank(treasury);
        vm.expectRevert(liquidity_locker.bad_unlock_time.selector);
        L.extend_block(id, uint40(B - 1));
    }

    // ───────────────────────── the long horizon, end to end ─────────────────────────

    /// Both gates, a century apart, carried to maturity and withdrawn.
    function test_ACenturyUnderBothGatesMaturesAndWithdraws() public {
        uint256 blocksPerCentury = CENTURY / 12; // Ethereum's cadence
        vm.prank(treasury);
        uint256 id = L.lock_until(
            address(lp), 500_000 ether, uint48(T + CENTURY), uint40(B + blocksPerCentury), dao
        );

        (uint256 secs, uint256 blks) = L.time_remaining(id);
        assertEq(secs, CENTURY);
        assertEq(blks, blocksPerCentury);

        _advance(CENTURY - 1);
        _roll(blocksPerCentury);
        vm.prank(dao);
        vm.expectRevert(liquidity_locker.still_locked.selector); // one second short
        L.withdraw(id);

        _advance(1);
        vm.prank(dao);
        L.withdraw(id);
        assertEq(lp.balanceOf(dao), 500_000 ether, "a century later, whole");
    }

    /// Two hundred years is representable in both gates and in both cursors.
    function test_TwoCenturiesIsWithinBothHorizons() public {
        uint256 max = L.MAX_LOCK_DURATION();
        uint256 maxBlocks = max / 12;
        vm.prank(treasury);
        uint256 id = L.lock_until(address(lp), 1_000 ether, uint48(T + max), uint40(B + maxBlocks), dao);
        (uint48 at, uint40 blk) = L.gates_of(id);
        assertEq(at, uint48(T + max));
        assertEq(blk, uint40(B + maxBlocks));
        assertTrue(L.is_locked(id));
    }

    // ───────────────────────── the gates are not a way in ─────────────────────────

    /// The whole point: no path, through either gate, lets anyone open a lock early.
    function test_NoGateCanEverBeBroughtForward() public {
        vm.prank(treasury);
        uint256 id = L.lock_until(address(lp), 1_000 ether, uint48(T + YEAR), uint40(B + 100_000), dao);

        vm.startPrank(dao);
        vm.expectRevert(liquidity_locker.not_shortenable.selector);
        L.extend(id, uint48(T + DAY));
        vm.expectRevert(liquidity_locker.not_shortenable.selector);
        L.extend_block(id, uint40(B + 1));
        vm.stopPrank();

        // assignment moves who may open it, never when
        vm.prank(dao);
        L.assign(id, stranger);
        (uint48 at, uint40 blk) = L.gates_of(id);
        assertEq(at, uint48(T + YEAR));
        assertEq(blk, uint40(B + 100_000));
        vm.prank(stranger);
        vm.expectRevert(liquidity_locker.still_locked.selector);
        L.withdraw(id);
    }

    /// A stranger cannot lengthen someone's lock either — extension is not a weapon.
    function test_ExtensionIsNotAvailableToStrangers() public {
        vm.prank(treasury);
        uint256 id = L.lock_default(address(lp), 1_000 ether, dao);
        vm.startPrank(stranger);
        vm.expectRevert(liquidity_locker.not_beneficiary.selector);
        L.extend(id, uint48(T + YEAR));
        vm.expectRevert(liquidity_locker.not_beneficiary.selector);
        L.extend_by(id, YEAR);
        vm.expectRevert(liquidity_locker.not_beneficiary.selector);
        L.extend_block_by(id, 1_000);
        vm.stopPrank();
    }

    /// A withdrawn lock is closed to both gates.
    function test_AWithdrawnLockCannotBeExtended() public {
        uint256 id = _lockDefault(1_000 ether);
        _advance(QUARTER);
        vm.prank(treasury);
        L.withdraw(id);
        vm.startPrank(treasury);
        vm.expectRevert(liquidity_locker.already_withdrawn.selector);
        L.extend_default(id);
        vm.expectRevert(liquidity_locker.already_withdrawn.selector);
        L.extend_block_by(id, 100);
        vm.stopPrank();
    }

    /// Principal is untouchable while either gate holds, sweep included.
    function test_SweepCannotReachPrincipalBehindTheBlockGate() public {
        vm.prank(treasury);
        L.lock_until(address(lp), 1_000 ether, 0, uint40(B + 1_000), address(0));
        vm.expectRevert(liquidity_locker.nothing_to_sweep.selector);
        L.sweep_surplus(address(lp));
        assertEq(lp.balanceOf(address(L)), 1_000 ether);
    }
}
