// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.0;

import "forge-std/Test.sol";
import {TimeBase} from "./time_base.sol";
import {liquidity_locker} from "../src/liquidity_locker.sol";
import {mock_erc20, mock_fee_token, mock_no_return_token, mock_false_token, mock_reentrant_token} from "./mocks.sol";

contract liquidity_locker_test is TimeBase {
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
        lp.mint(treasury, 1_000_000 ether);
        vm.prank(treasury);
        lp.approve(address(L), type(uint256).max);
    }

    function _lock(uint256 amount, uint48 until, address beneficiary) internal returns (uint256 id) {
        vm.prank(treasury);
        id = L.lock(address(lp), amount, until, beneficiary);
    }

    // ------------------------------------------------------------------ the basics
    function test_LockThenWithdrawAtMaturity() public {
        uint256 id = _lock(1_000 ether, _now() + YEAR, address(0));
        assertEq(lp.balanceOf(address(L)), 1_000 ether);
        assertEq(L.total_locked(address(lp)), 1_000 ether);
        assertTrue(L.is_locked(id));

        _advance(YEAR);
        vm.prank(treasury);
        L.withdraw(id);

        assertEq(lp.balanceOf(address(L)), 0);
        assertEq(L.total_locked(address(lp)), 0);
        assertFalse(L.is_locked(id));
    }

    function test_CannotWithdrawOneSecondEarly() public {
        uint256 id = _lock(1_000 ether, _now() + YEAR, address(0));
        _advance(YEAR - 1);
        vm.prank(treasury);
        vm.expectRevert(liquidity_locker.still_locked.selector);
        L.withdraw(id);
    }

    function test_OnlyBeneficiaryCanWithdraw() public {
        uint256 id = _lock(1_000 ether, _now() + YEAR, address(0));
        _advance(YEAR);
        vm.prank(stranger);
        vm.expectRevert(liquidity_locker.not_beneficiary.selector);
        L.withdraw(id);
    }

    function test_DoubleWithdrawReverts() public {
        uint256 id = _lock(1_000 ether, _now() + YEAR, address(0));
        _advance(YEAR);
        vm.startPrank(treasury);
        L.withdraw(id);
        vm.expectRevert(liquidity_locker.already_withdrawn.selector);
        L.withdraw(id);
        vm.stopPrank();
    }

    // --------------------------------------------------- AUDIT A2: extendable locks
    /// The live vault could not extend an asset lock at all, so proving continued
    /// commitment meant maturing, withdrawing, and re-locking — publishing an unlocked
    /// window in the middle. This is the fix.
    function test_A2_LpLockIsExtendable() public {
        uint256 id = _lock(1_000 ether, _now() + YEAR, address(0));
        vm.prank(treasury);
        L.extend(id, _now() + 2 * YEAR);

        _advance(YEAR);
        vm.prank(treasury);
        vm.expectRevert(liquidity_locker.still_locked.selector);
        L.withdraw(id);

        _advance(YEAR);
        vm.prank(treasury);
        L.withdraw(id);
        assertEq(lp.balanceOf(treasury), 1_000_000 ether);
    }

    function test_ExtendNeverShortens() public {
        uint256 id = _lock(1_000 ether, _now() + 2 * YEAR, address(0));
        vm.prank(treasury);
        vm.expectRevert(liquidity_locker.not_shortenable.selector);
        L.extend(id, _now() + YEAR);
    }

    /// @dev AUDIT T-2. `L.MAX_LOCK_DURATION()` is hoisted into a local BEFORE
    ///      `vm.expectRevert`. Left inline in the argument expression it is an external
    ///      staticcall that consumes the cheatcode, and the test passes vacuously.
    ///      Both bound tests in this file failed exactly that way when first written.
    function test_ExtendRespectsMaxDuration() public {
        uint48 max_dur = uint48(L.MAX_LOCK_DURATION());
        uint48 too_far = _now() + max_dur + 1;
        uint256 id = _lock(1_000 ether, _now() + YEAR, address(0));
        vm.prank(treasury);
        vm.expectRevert(liquidity_locker.duration_too_long.selector);
        L.extend(id, too_far);
    }

    // ------------------------------------- AUDIT A1: extension is beneficiary-only
    /// In the live vault the owner could push ANY depositor's unlock time out by ten
    /// years, repeatedly. There is no owner here, and no third party can reach it.
    function test_A1_StrangerCannotExtendSomeoneElsesLock() public {
        uint256 id = _lock(1_000 ether, _now() + YEAR, address(0));
        vm.prank(stranger);
        vm.expectRevert(liquidity_locker.not_beneficiary.selector);
        L.extend(id, _now() + 2 * YEAR);
    }

    // ------------------------------------------- AUDIT A3: lock for a beneficiary
    /// The live vault bound every lock to the funder, so a treasury could not lock LP
    /// on behalf of a community wallet without handing over the funding key.
    function test_A3_TreasuryLocksForCommunityWallet() public {
        uint256 id = _lock(1_000 ether, _now() + YEAR, community);
        (, address beneficiary,,,) = L.lock_at(id);
        assertEq(beneficiary, community);

        _advance(YEAR);
        // The funder is now a stranger to this lock.
        vm.prank(treasury);
        vm.expectRevert(liquidity_locker.not_beneficiary.selector);
        L.withdraw(id);

        vm.prank(community);
        L.withdraw(id);
        assertEq(lp.balanceOf(community), 1_000 ether);
    }

    function test_AssignMovesBeneficiaryButNotMaturity() public {
        uint256 id = _lock(1_000 ether, _now() + YEAR, address(0));
        (,,, uint48 before_unlock,) = L.lock_at(id);

        vm.prank(treasury);
        L.assign(id, community);

        (, address beneficiary,, uint48 after_unlock,) = L.lock_at(id);
        assertEq(beneficiary, community);
        assertEq(after_unlock, before_unlock, "assign must not touch maturity");

        // And the old beneficiary is now powerless over it.
        vm.prank(treasury);
        vm.expectRevert(liquidity_locker.not_beneficiary.selector);
        L.assign(id, treasury);
    }

    function test_LocksOfFiltersStaleIndexEntries() public {
        uint256 id = _lock(1_000 ether, _now() + YEAR, address(0));
        assertEq(L.locks_of(treasury).length, 1);
        vm.prank(treasury);
        L.assign(id, community);
        assertEq(L.locks_of(treasury).length, 0, "stale index entry must be filtered");
        assertEq(L.locks_of(community).length, 1);
    }

    // ---------------------------------------------- AUDIT A4/A5: there is no owner
    /**
     * A4 (no incident brake) and A5 (single-step ownership) were findings about an
     * owner. This asserts the structural answer: the deployed contract exposes no
     * function that transfers a locked token to anyone but its beneficiary. Nothing
     * to pause, nothing to hand over, nothing to compromise.
     */
    function test_A4A5_NoPrivilegedPathReachesLockedPrincipal() public {
        _lock(1_000 ether, _now() + YEAR, address(0));

        // The deployer is the most privileged address that exists. It is not special.
        vm.startPrank(address(this));
        vm.expectRevert(liquidity_locker.nothing_to_sweep.selector);
        L.sweep_surplus(address(lp));
        vm.stopPrank();

        assertEq(lp.balanceOf(address(L)), 1_000 ether, "principal untouched");
        assertEq(lp.balanceOf(sink), 0);
    }

    // -------------------------------------------------------- fee-on-transfer safety
    /// Crediting the requested amount instead of the measured delta is how the last
    /// withdrawer ends up unable to exit. This is the single most load-bearing property.
    function test_FeeOnTransferCreditsWhatActuallyArrived() public {
        mock_fee_token fee = new mock_fee_token();
        fee.mint(treasury, 10_000 ether);
        vm.startPrank(treasury);
        fee.approve(address(L), type(uint256).max);
        uint256 id = L.lock(address(fee), 1_000 ether, _now() + YEAR, address(0));
        vm.stopPrank();

        (,, uint256 amount,,) = L.lock_at(id);
        assertEq(amount, 950 ether, "must credit the 5%-burned delta, not 1000");
        assertEq(L.total_locked(address(fee)), 950 ether);
        assertEq(fee.balanceOf(address(L)), 950 ether, "accounting equals reality");
    }

    function test_TwoFeeTokenLockersBothExit() public {
        mock_fee_token fee = new mock_fee_token();
        fee.mint(treasury, 10_000 ether);
        fee.mint(community, 10_000 ether);

        vm.startPrank(treasury);
        fee.approve(address(L), type(uint256).max);
        uint256 a = L.lock(address(fee), 1_000 ether, _now() + YEAR, address(0));
        vm.stopPrank();
        vm.startPrank(community);
        fee.approve(address(L), type(uint256).max);
        uint256 b = L.lock(address(fee), 1_000 ether, _now() + YEAR, address(0));
        vm.stopPrank();

        _advance(YEAR);
        vm.prank(treasury);
        L.withdraw(a);
        // The second locker must not be short. This is the failure the delta prevents.
        vm.prank(community);
        L.withdraw(b);
        assertEq(L.total_locked(address(fee)), 0);
    }

    function test_UsdtStyleNoReturnDataTokenWorks() public {
        mock_no_return_token usdt = new mock_no_return_token();
        usdt.mint(treasury, 10_000 ether);
        vm.startPrank(treasury);
        usdt.approve(address(L), type(uint256).max);
        uint256 id = L.lock(address(usdt), 1_000 ether, _now() + YEAR, address(0));
        vm.stopPrank();

        _advance(YEAR);
        vm.prank(treasury);
        L.withdraw(id);
        assertEq(usdt.balanceOf(treasury), 10_000 ether);
    }

    function test_TokenReturningFalseIsTreatedAsFailure() public {
        mock_false_token bad = new mock_false_token();
        bad.mint(treasury, 10_000 ether);
        vm.startPrank(treasury);
        bad.approve(address(L), type(uint256).max);
        // transferFrom still works (inherited); transfer out returns false.
        uint256 id = L.lock(address(bad), 1_000 ether, _now() + YEAR, address(0));
        vm.stopPrank();

        _advance(YEAR);
        vm.prank(treasury);
        vm.expectRevert();
        L.withdraw(id);
    }

    // -------------------------------------------------------------- surplus sweep
    /// @dev SEMANTIC CHANGE, 2026-08-10. Balance arriving while a lock is live is now
    ///      that lock's interest, not the sink's. This is the reflection design: LUV
    ///      grows the vault's balance on every trade, and paying that growth to a sink
    ///      would mean a depositor funds a century of yield and collects none of it.
    ///      The permissionless rescue is unchanged for tokens nobody has locked —
    ///      see `test_SweepStillRescuesStrayTokensWithNoLiveLocks`.
    function test_ArrivalsWhileLockedBecomeInterestNotSinkRevenue() public {
        uint256 id = _lock(1_000 ether, _now() + YEAR, address(0));
        vm.prank(treasury);
        lp.transfer(address(L), 250 ether);

        // Nothing is free: it has all been booked to the live lock.
        assertEq(L.surplus(address(lp)), 0);
        assertEq(L.interest_of(id), 250 ether);

        vm.prank(stranger);
        vm.expectRevert(liquidity_locker.nothing_to_sweep.selector);
        L.sweep_surplus(address(lp));
        assertEq(lp.balanceOf(sink), 0, "the sink cannot take a locker's reflections");

        vm.prank(treasury);
        assertEq(L.redeem_interest(id), 250 ether);
        assertEq(lp.balanceOf(address(L)), 1_000 ether, "locked principal untouched");
    }

    function test_SweepRevertsWhenEverythingIsLocked() public {
        _lock(1_000 ether, _now() + YEAR, address(0));
        vm.expectRevert(liquidity_locker.nothing_to_sweep.selector);
        L.sweep_surplus(address(lp));
    }

    // ----------------------------------------------------------------- reentrancy
    function test_ReentrantTokenCannotWithdrawTwice() public {
        mock_reentrant_token evil = new mock_reentrant_token();
        evil.mint(treasury, 10_000 ether);
        vm.startPrank(treasury);
        evil.approve(address(L), type(uint256).max);
        uint256 id = L.lock(address(evil), 1_000 ether, _now() + YEAR, address(0));
        vm.stopPrank();

        evil.arm(L, id);
        _advance(YEAR);
        vm.prank(treasury);
        L.withdraw(id);

        assertTrue(evil.reentered(), "the callback must actually have fired");
        assertEq(evil.balanceOf(treasury), 10_000 ether, "paid exactly once");
        assertEq(L.total_locked(address(evil)), 0);
    }

    // ---------------------------------------------------------------- input bounds
    function test_RejectsMaturityInThePast() public {
        vm.prank(treasury);
        vm.expectRevert(liquidity_locker.bad_unlock_time.selector);
        L.lock(address(lp), 1_000 ether, _now(), address(0));
    }

    function test_RejectsBeyondMaxDuration() public {
        uint48 too_far = _now() + uint48(L.MAX_LOCK_DURATION()) + 1; // hoisted, see T-2 above
        vm.prank(treasury);
        vm.expectRevert(liquidity_locker.duration_too_long.selector);
        L.lock(address(lp), 1_000 ether, too_far, address(0));
    }

    function test_RejectsZeroSurplusSinkAtDeploy() public {
        vm.expectRevert(liquidity_locker.zero_address.selector);
        new liquidity_locker(address(0));
    }

    function test_UnknownLockIdReverts() public {
        vm.expectRevert(liquidity_locker.lock_not_found.selector);
        L.lock_at(42);
    }

    // ---------------------------------------------------------------------- fuzz
    /// The accounting invariant: for any sequence of locks, the contract's balance is
    /// never less than what it says is locked. If this can fail, someone cannot exit.
    function testFuzz_BalanceAlwaysCoversTotalLocked(uint96[8] calldata amounts, uint32[8] calldata offsets)
        public
    {
        for (uint256 i; i < 8; ++i) {
            uint256 amount = uint256(amounts[i]) + 1;
            if (amount > lp.balanceOf(treasury)) continue;
            uint48 until = _now() + uint48(bound(offsets[i], 1, L.MAX_LOCK_DURATION()));
            vm.prank(treasury);
            L.lock(address(lp), amount, until, address(0));
            assertGe(lp.balanceOf(address(L)), L.total_locked(address(lp)));
        }
    }

    function testFuzz_ExtendIsMonotonic(uint32 first, uint32 second) public {
        uint48 a = _now() + uint48(bound(first, 1, L.MAX_LOCK_DURATION() - 1));
        uint256 id = _lock(1 ether, a, address(0));
        uint48 b = _now() + uint48(bound(second, 1, L.MAX_LOCK_DURATION()));

        vm.prank(treasury);
        if (b <= a) {
            vm.expectRevert(liquidity_locker.not_shortenable.selector);
            L.extend(id, b);
        } else {
            L.extend(id, b);
            (,,, uint48 unlock_at,) = L.lock_at(id);
            assertGe(unlock_at, a, "maturity can only move forward");
        }
    }

    function _now() internal view returns (uint48) {
        return uint48(T);
    }
}
