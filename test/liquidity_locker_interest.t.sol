// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.0;

import "forge-std/Test.sol";
import {TimeBase} from "./time_base.sol";
import {liquidity_locker} from "../src/liquidity_locker.sol";
import {mock_erc20} from "./mocks.sol";

/**
 * Interest redemption — hold the principal, redeem the reflections.
 *
 * A reflection token grows the locker's balance without a transfer in. The vault must
 * pay that growth to the locks that earned it and must never let it reach principal in
 * either direction: interest out is not a withdrawal, and a redemption must not shorten
 * a lock, reduce its amount, or make it insolvent.
 *
 * Reflections are simulated by transferring directly to the locker, which is exactly
 * what a reflection token does to a balance — no hook, no callback, just a larger
 * `balanceOf` than the vault's own books record.
 */
contract liquidity_locker_interest_test is TimeBase {
    liquidity_locker internal L;
    mock_erc20 internal lp;

    address internal treasury = address(0xA11CE);
    address internal community = address(0xB0B);
    address internal stranger = address(0xCAFE);
    address internal sink = address(0x5142);

    uint48 internal constant YEAR = 365 days;

    function setUp() public {
        _startClock(1_800_000_000);
        L = new liquidity_locker(sink);
        lp = new mock_erc20();
        lp.mint(treasury, 10_000_000 ether);
        vm.prank(treasury);
        lp.approve(address(L), type(uint256).max);
    }

    /// @dev Per audit T-1 the clock is a cursor, never `block.timestamp + X` chained.
    function _now() internal view returns (uint48) {
        return uint48(T);
    }

    function _lock(uint256 amount, uint48 until, address beneficiary) internal returns (uint256 id) {
        vm.prank(treasury);
        id = L.lock(address(lp), amount, until, beneficiary);
    }

    /// @dev A reflection arriving: balance grows, books do not.
    function _reflect(uint256 amount) internal {
        vm.prank(treasury);
        lp.transfer(address(L), amount);
    }

    // ------------------------------------------------------- the core proposition
    function test_InterestIsRedeemableWhilePrincipalStaysLocked() public {
        uint256 id = _lock(1_000 ether, _now() + YEAR, address(0));
        _reflect(100 ether);

        assertEq(L.interest_of(id), 100 ether, "the whole surplus belongs to the only lock");

        vm.prank(treasury);
        uint256 paid = L.redeem_interest(id);

        assertEq(paid, 100 ether);
        assertEq(lp.balanceOf(address(L)), 1_000 ether, "principal untouched");
        assertEq(L.total_locked(address(lp)), 1_000 ether, "books untouched");
        assertTrue(L.is_locked(id), "still locked; interest is not an exit");
        (,, uint256 amount, uint48 unlock_at,) = L.lock_at(id);
        assertEq(amount, 1_000 ether, "principal amount unchanged");
        assertEq(unlock_at, _now() + YEAR, "maturity unchanged");
    }

    function test_RedeemingTwiceInOneBlockPaysNothingTheSecondTime() public {
        uint256 id = _lock(1_000 ether, _now() + YEAR, address(0));
        _reflect(100 ether);

        vm.prank(treasury);
        L.redeem_interest(id);
        // The surplus it was computed from is gone, so there is nothing left to take.
        vm.prank(treasury);
        vm.expectRevert(liquidity_locker.nothing_to_sweep.selector);
        L.redeem_interest(id);
    }

    function test_InterestAccruesAgainAfterRedemption() public {
        uint256 id = _lock(1_000 ether, _now() + YEAR, address(0));
        _reflect(100 ether);
        vm.prank(treasury);
        L.redeem_interest(id);

        _advance(30 days);
        _reflect(40 ether);
        assertEq(L.interest_of(id), 40 ether);
        vm.prank(treasury);
        assertEq(L.redeem_interest(id), 40 ether);
    }

    // ------------------------------------------------------------------ pro rata
    function test_InterestSplitsProRataAcrossLocks() public {
        uint256 a = _lock(3_000 ether, _now() + YEAR, treasury);
        uint256 b = _lock(1_000 ether, _now() + YEAR, community);
        _reflect(400 ether); // 4,000 locked → 300 / 100

        assertEq(L.interest_of(a), 300 ether);
        assertEq(L.interest_of(b), 100 ether);

        vm.prank(treasury);
        assertEq(L.redeem_interest(a), 300 ether);
        vm.prank(community);
        assertEq(L.redeem_interest(b), 100 ether);

        assertEq(lp.balanceOf(address(L)), 4_000 ether, "only principal remains");
    }

    function test_OneRedeemerCannotTakeAnothersShare() public {
        uint256 a = _lock(1_000 ether, _now() + YEAR, treasury);
        uint256 b = _lock(1_000 ether, _now() + YEAR, community);
        _reflect(200 ether);

        vm.prank(treasury);
        L.redeem_interest(a);
        // B's share survives A having gone first.
        assertEq(L.interest_of(b), 100 ether);
        vm.prank(community);
        assertEq(L.redeem_interest(b), 100 ether);
    }

    // ------------------------------------------------------------------- refusals
    function test_OnlyBeneficiaryMayRedeem() public {
        uint256 id = _lock(1_000 ether, _now() + YEAR, address(0));
        _reflect(100 ether);
        vm.prank(stranger);
        vm.expectRevert(liquidity_locker.not_beneficiary.selector);
        L.redeem_interest(id);
    }

    function test_WithdrawnLockEarnsNothing() public {
        uint256 id = _lock(1_000 ether, _now() + YEAR, address(0));
        _advance(YEAR);
        vm.prank(treasury);
        L.withdraw(id);

        _reflect(50 ether);
        assertEq(L.interest_of(id), 0);
        vm.prank(treasury);
        vm.expectRevert(liquidity_locker.already_withdrawn.selector);
        L.redeem_interest(id);
    }

    function test_RedeemToZeroAddressReverts() public {
        uint256 id = _lock(1_000 ether, _now() + YEAR, address(0));
        _reflect(10 ether);
        vm.prank(treasury);
        vm.expectRevert(liquidity_locker.zero_address.selector);
        L.redeem_interest_to(id, address(0));
    }

    function test_RedeemToNominatedAddress() public {
        uint256 id = _lock(1_000 ether, _now() + YEAR, address(0));
        _reflect(60 ether);
        vm.prank(treasury);
        L.redeem_interest_to(id, community);
        assertEq(lp.balanceOf(community), 60 ether);
    }

    function test_MaturedLockMayStillRedeemWithoutWithdrawing() public {
        uint256 id = _lock(1_000 ether, _now() + YEAR, address(0));
        _advance(YEAR);
        _reflect(75 ether);
        // Maturity and interest are independent: the gate opened, nobody walked through.
        vm.prank(treasury);
        assertEq(L.redeem_interest(id), 75 ether);
        assertEq(L.total_locked(address(lp)), 1_000 ether);
    }

    // --------------------------------------------------- sweep no longer competes
    function test_SweepCannotTakeInterestOwedToLiveLocks() public {
        _lock(1_000 ether, _now() + YEAR, address(0));
        _reflect(250 ether);
        // Under the old design a stranger swept this to the sink. It is the lockers'.
        vm.prank(stranger);
        vm.expectRevert(liquidity_locker.nothing_to_sweep.selector);
        L.sweep_surplus(address(lp));
        assertEq(lp.balanceOf(sink), 0);
    }

    function test_SweepStillRescuesStrayTokensWithNoLiveLocks() public {
        mock_erc20 stray = new mock_erc20();
        stray.mint(stranger, 500 ether);
        vm.prank(stranger);
        stray.transfer(address(L), 500 ether);

        // Nothing is locked in `stray`, so the rescue path is intact.
        vm.prank(stranger);
        assertEq(L.sweep_surplus(address(stray)), 500 ether);
        assertEq(stray.balanceOf(sink), 500 ether, "immutable destination");
    }

    function test_SweepBecomesAvailableAgainOnceLocksClose() public {
        uint256 id = _lock(1_000 ether, _now() + YEAR, address(0));
        _reflect(100 ether);
        _advance(YEAR);
        uint256 before = lp.balanceOf(treasury);
        vm.prank(treasury);
        L.withdraw(id);
        // Withdraw settles interest WITH principal — leaving it behind would strand it
        // in `promised` with no claimant. So the vault is empty and there is nothing
        // for the sink to rescue, which is the correct end state.
        assertEq(lp.balanceOf(treasury) - before, 1_100 ether, "principal + interest");
        assertEq(lp.balanceOf(address(L)), 0);

        vm.prank(stranger);
        vm.expectRevert(liquidity_locker.nothing_to_sweep.selector);
        L.sweep_surplus(address(lp));
    }

    // ------------------------------------------------------------------ solvency
    function testFuzz_RedemptionNeverBreaksSolvency(
        uint96 p1,
        uint96 p2,
        uint96 reflection
    ) public {
        p1 = uint96(bound(p1, 1 ether, 100_000 ether));
        p2 = uint96(bound(p2, 1 ether, 100_000 ether));
        reflection = uint96(bound(reflection, 0, 500_000 ether));

        uint256 a = _lock(p1, _now() + YEAR, treasury);
        uint256 b = _lock(p2, _now() + YEAR, community);
        if (reflection > 0) _reflect(reflection);

        if (L.interest_of(a) > 0) {
            vm.prank(treasury);
            L.redeem_interest(a);
        }
        if (L.interest_of(b) > 0) {
            vm.prank(community);
            L.redeem_interest(b);
        }
        // The invariant the whole vault rests on.
        assertGe(
            lp.balanceOf(address(L)),
            L.total_locked(address(lp)),
            "balance must always cover the books"
        );
        // And principal is still fully payable at maturity.
        _advance(YEAR);
        vm.prank(treasury);
        L.withdraw(a);
        vm.prank(community);
        L.withdraw(b);
        assertEq(lp.balanceOf(treasury) >= p1, true);
    }

    function testFuzz_RedemptionNeverExceedsSurplus(uint96 principal, uint96 reflection) public {
        principal = uint96(bound(principal, 1 ether, 1_000_000 ether));
        reflection = uint96(bound(reflection, 1 ether, 1_000_000 ether));
        uint256 id = _lock(principal, _now() + YEAR, address(0));
        _reflect(reflection);

        uint256 before = lp.balanceOf(address(L));
        vm.prank(treasury);
        uint256 paid = L.redeem_interest(id);

        assertLe(paid, reflection, "never pays more than arrived");
        assertEq(lp.balanceOf(address(L)), before - paid);
        assertGe(lp.balanceOf(address(L)), principal, "principal is never the source");
    }

    // -------------------------------------------------------------- the horizon
    function test_LockCanStandTwoHundredYears() public {
        uint48 twoCenturies = uint48(L.MAX_LOCK_DURATION());
        uint256 id = _lock(1_000 ether, _now() + twoCenturies, address(0));

        _advance(uint48(100 * 365 days)); // a century in
        assertTrue(L.is_locked(id), "still locked after 100 years");
        vm.prank(treasury);
        vm.expectRevert(liquidity_locker.still_locked.selector);
        L.withdraw(id);

        // and interest still redeems, a hundred years later
        _reflect(500 ether);
        vm.prank(treasury);
        assertEq(L.redeem_interest(id), 500 ether);
    }

    function test_HorizonCoversTheStatedCommitments() public view {
        uint256 max = L.MAX_LOCK_DURATION();
        assertGe(max, 100 * 365 days, "the 100-year locker mandate");
        assertGe(max, 140 * 365 days, "140 years of Uniswap");
        assertGe(max, 200 * 365 days, "the Arweave 200-year storage standard");
    }

    function test_BeyondTheHorizonIsStillRefused() public {
        uint48 tooLong = uint48(_now() + L.MAX_LOCK_DURATION() + 1 days);
        vm.prank(treasury);
        vm.expectRevert(liquidity_locker.duration_too_long.selector);
        L.lock(address(lp), 1_000 ether, tooLong, address(0));
    }
}
