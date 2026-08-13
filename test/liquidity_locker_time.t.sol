// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.0;

import "forge-std/Test.sol";
import {TimeBase} from "./time_base.sol";
import {liquidity_locker} from "../src/liquidity_locker.sol";
import {mock_erc20} from "./mocks.sol";

/**
 * Time-focused suite for liquidity_locker: maturity boundaries to the second, extension
 * across elapsed time, the ten-year horizon end to end, and succession (`assign`) leaving
 * maturity untouched as time passes. All time moves through the absolute cursor in TimeBase
 * (AUDIT T-1: never chain vm.warp(block.timestamp + X) under via_ir).
 */
contract liquidity_locker_time_test is TimeBase {
    liquidity_locker internal L;
    mock_erc20 internal lp;

    address internal treasury = address(0xA11CE);
    address internal daoMultisig = address(0xDA0);
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

    function _now() internal view returns (uint48) { return uint48(T); }

    function _lock(uint256 amount, uint48 until, address beneficiary) internal returns (uint256 id) {
        vm.prank(treasury);
        id = L.lock(address(lp), amount, until, beneficiary);
    }

    // ── maturity boundary, to the second ──
    function test_WithdrawRevertsOneSecondBeforeMaturity() public {
        uint48 until = _now() + YEAR;
        uint256 id = _lock(1_000 ether, until, address(0));
        _advance(uint256(YEAR) - 1); // one second short
        vm.prank(treasury);
        vm.expectRevert(liquidity_locker.still_locked.selector);
        L.withdraw(id);
    }

    function test_WithdrawSucceedsExactlyAtMaturity() public {
        uint48 until = _now() + YEAR;
        uint256 id = _lock(1_000 ether, until, address(0));
        _advance(uint256(YEAR)); // block.timestamp == unlock_at; guard is `< unlock_at`, so this opens
        vm.prank(treasury);
        L.withdraw(id);
        assertEq(lp.balanceOf(treasury), 1_000_000 ether);
    }

    // ── lock creation rejects a maturity in the past / beyond the horizon ──
    function test_LockRejectsMaturityInThePast() public {
        _advance(10 days);
        vm.prank(treasury);
        vm.expectRevert(liquidity_locker.bad_unlock_time.selector);
        L.lock(address(lp), 1_000 ether, _now() - 1, address(0));
    }

    function test_LockRejectsBeyondTenYearHorizon() public {
        uint256 maxDur = L.MAX_LOCK_DURATION();
        vm.prank(treasury);
        vm.expectRevert(liquidity_locker.duration_too_long.selector);
        L.lock(address(lp), 1_000 ether, _now() + uint48(maxDur) + 1, address(0));
    }

    // ── extend across elapsed time ──
    function test_ExtendPartwayThroughPushesMaturityOut() public {
        uint48 until = _now() + YEAR;
        uint256 id = _lock(1_000 ether, until, address(0));

        _advance(200 days);
        uint48 newUntil = _now() + 300 days;
        vm.prank(treasury);
        L.extend(id, newUntil);

        // reach the ORIGINAL maturity: still locked
        _advance(165 days); // 200 + 165 = 365 = original term
        vm.prank(treasury);
        vm.expectRevert(liquidity_locker.still_locked.selector);
        L.withdraw(id);

        // reach the NEW maturity: opens
        _advance(uint256(newUntil) - uint256(_now()));
        vm.prank(treasury);
        L.withdraw(id);
        assertEq(lp.balanceOf(treasury), 1_000_000 ether);
    }

    function test_ExtendCannotShortenAfterTimePasses() public {
        uint48 until = _now() + 2 * YEAR;
        uint256 id = _lock(1_000 ether, until, address(0));
        _advance(100 days);
        vm.prank(treasury);
        vm.expectRevert(liquidity_locker.not_shortenable.selector);
        L.extend(id, until - 1);
    }

    function test_ExtendRejectsBeyondTenYearHorizonOverTime() public {
        uint48 until = _now() + YEAR;
        uint256 id = _lock(1_000 ether, until, address(0));
        _advance(30 days);
        uint256 maxDur = L.MAX_LOCK_DURATION();
        vm.prank(treasury);
        vm.expectRevert(liquidity_locker.duration_too_long.selector);
        L.extend(id, _now() + uint48(maxDur) + 1);
    }

    // ── the full ten-year horizon, end to end ──
    function test_TenYearHorizonLockAndWithdraw() public {
        uint256 maxDur = L.MAX_LOCK_DURATION(); // 3650 days
        uint48 until = _now() + uint48(maxDur);
        uint256 id = _lock(5_000 ether, until, address(0));

        _advance(maxDur - 1); // one second short of a decade
        vm.prank(treasury);
        vm.expectRevert(liquidity_locker.still_locked.selector);
        L.withdraw(id);

        _advance(1); // the decade completes
        vm.prank(treasury);
        L.withdraw(id);
        assertEq(L.total_locked(address(lp)), 0);
    }

    // ── succession over time: assign hands custody without moving maturity ──
    function test_AssignHandsCustodyButMaturityIsUntouched() public {
        uint48 until = _now() + YEAR;
        uint256 id = _lock(1_000 ether, until, address(0)); // beneficiary defaults to treasury

        _advance(180 days);
        // treasury rotates custody to the DAO multisig mid-lock — no unlocked interval
        vm.prank(treasury);
        L.assign(id, daoMultisig);

        // the OLD beneficiary can no longer withdraw, even after maturity
        _advance(185 days); // now past the original one-year term
        vm.prank(treasury);
        vm.expectRevert(liquidity_locker.not_beneficiary.selector);
        L.withdraw(id);

        // the NEW beneficiary withdraws at the unchanged maturity
        vm.prank(daoMultisig);
        L.withdraw(id);
        assertEq(lp.balanceOf(daoMultisig), 1_000 ether);
    }

    // ── assign before maturity does not let the new holder exit early ──
    function test_AssignBeforeMaturityStillRespectsTheClock() public {
        uint48 until = _now() + YEAR;
        uint256 id = _lock(1_000 ether, until, address(0));
        vm.prank(treasury);
        L.assign(id, daoMultisig);

        _advance(100 days); // still locked
        vm.prank(daoMultisig);
        vm.expectRevert(liquidity_locker.still_locked.selector);
        L.withdraw(id);
    }
}
