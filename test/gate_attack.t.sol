// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * GATE ATTACK — an adversarial pass at the TIME and BLOCK gates.
 *
 * The lockers' whole product claim is that maturity cannot be brought forward by anyone,
 * including the deployer. This file does not re-test that it works; it tries to BREAK it.
 * Every test here is written as an attacker: the name says what is being attempted, and a
 * PASS means the attempt failed.
 *
 * The attack surface for a time-gated vault:
 *   1. boundary        — off-by-one at maturity, in both directions, on both gates
 *   2. proposer drift  — a validator nudging block.timestamp to open a lock early
 *   3. the later gate  — one gate passed must never be enough when the other has not
 *   4. extend-only     — every path that writes maturity must refuse to lower it
 *   5. authority       — nobody but the beneficiary moves a lock, at any point
 *   6. succession      — assign() must transfer the right to open, not duplicate it
 *   7. re-entrancy     — a hostile token re-entering withdraw mid-transfer
 *   8. arithmetic      — overflow at the uint48/uint40 horizons
 */

import "forge-std/Test.sol";
import {liquidity_locker} from "../src/liquidity_locker.sol";
import {mock_erc20} from "./mocks.sol";

/// A token that calls back into the locker while it is paying out.
contract reentrant_token {
    string public name = "RE";
    string public symbol = "RE";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    liquidity_locker public target;
    uint256 public reenter_id;
    bool public armed;

    function mint(address to, uint256 v) external { balanceOf[to] += v; }
    function arm(liquidity_locker t, uint256 id) external { target = t; reenter_id = id; armed = true; }
    function approve(address s, uint256 v) external returns (bool) { allowance[msg.sender][s] = v; return true; }

    function transferFrom(address f, address t, uint256 v) external returns (bool) {
        if (allowance[f][msg.sender] != type(uint256).max) allowance[f][msg.sender] -= v;
        balanceOf[f] -= v; balanceOf[t] += v; return true;
    }

    function transfer(address t, uint256 v) external returns (bool) {
        balanceOf[msg.sender] -= v; balanceOf[t] += v;
        if (armed) { armed = false; target.withdraw(reenter_id); }   // the re-entry
        return true;
    }
}

contract gate_attack_test is Test {
    liquidity_locker internal lk;
    mock_erc20 internal tok;
    address internal constant SINK  = address(0x5151);
    address internal constant ALICE = address(0xA11CE0);
    address internal constant MALLORY = address(0xBAD);

    uint256 internal constant AMT = 1_000e18;

    function setUp() public {
        lk = new liquidity_locker(SINK);
        tok = new mock_erc20();
        tok.mint(ALICE, 10 * AMT);
        vm.prank(ALICE);
        tok.approve(address(lk), type(uint256).max);
        // a deterministic, non-zero starting point for both clocks
        vm.warp(1_800_000_000);
        vm.roll(20_000_000);
    }

    function _lock(uint48 unlock_at) internal returns (uint256 id) {
        vm.prank(ALICE);
        id = lk.lock(address(tok), AMT, unlock_at, ALICE);
    }

    // ─────────────────────────────────────────────── 1. boundary
    function test_attack_WithdrawOneSecondEarlyFails() public {
        uint48 t = uint48(block.timestamp + 90 days);
        uint256 id = _lock(t);
        vm.warp(t - 1);
        vm.prank(ALICE);
        vm.expectRevert(liquidity_locker.still_locked.selector);
        lk.withdraw(id);
    }

    function test_attack_WithdrawExactlyAtMaturitySucceeds() public {
        uint48 t = uint48(block.timestamp + 90 days);
        uint256 id = _lock(t);
        vm.warp(t);                       // the gate is `block.timestamp < unlock_at`
        vm.prank(ALICE);
        lk.withdraw(id);
        assertEq(tok.balanceOf(ALICE), 10 * AMT, "principal did not come home whole");
    }

    function test_attack_BlockGateOneBlockEarlyFails() public {
        uint40 b = uint40(block.number + 100_000);
        vm.prank(ALICE);
        uint256 id = lk.lock_until(address(tok), AMT, 0, b, ALICE);
        vm.roll(b - 1);
        vm.warp(block.timestamp + 3650 days);   // time long gone; the BLOCK must still hold
        vm.prank(ALICE);
        vm.expectRevert(liquidity_locker.still_locked.selector);
        lk.withdraw(id);
    }

    // ─────────────────────────────────────────────── 2. proposer drift
    /// A validator may nudge the timestamp within a tolerance. It must not buy a release.
    function test_attack_ProposerCannotWarpALockOpen() public {
        uint48 t = uint48(block.timestamp + 90 days);
        uint256 id = _lock(t);
        // the most a proposer could plausibly steal, and then some
        for (uint256 drift = 1; drift <= 900; drift += 149) {
            vm.warp(t - drift);
            vm.prank(ALICE);
            vm.expectRevert(liquidity_locker.still_locked.selector);
            lk.withdraw(id);
        }
    }

    /// The block gate is consensus, not a claim: no warp of any size opens it.
    function test_attack_NoAmountOfTimeOpensABlockGate() public {
        uint40 b = uint40(block.number + 1_000_000);
        vm.prank(ALICE);
        uint256 id = lk.lock_until(address(tok), AMT, 0, b, ALICE);
        vm.warp(block.timestamp + 200 * 365 days);   // two centuries of clock
        vm.prank(ALICE);
        vm.expectRevert(liquidity_locker.still_locked.selector);
        lk.withdraw(id);
    }

    // ─────────────────────────────────────────────── 3. the later gate governs
    function test_attack_TimePassedButBlockNotStaysShut() public {
        uint48 t = uint48(block.timestamp + 30 days);
        uint40 b = uint40(block.number + 1_000_000);
        vm.prank(ALICE);
        uint256 id = lk.lock_until(address(tok), AMT, t, b, ALICE);
        vm.warp(t + 1 days);            // time gate open
        vm.prank(ALICE);
        vm.expectRevert(liquidity_locker.still_locked.selector);
        lk.withdraw(id);
    }

    function test_attack_BlockPassedButTimeNotStaysShut() public {
        uint48 t = uint48(block.timestamp + 3650 days);
        uint40 b = uint40(block.number + 10);
        vm.prank(ALICE);
        uint256 id = lk.lock_until(address(tok), AMT, t, b, ALICE);
        vm.roll(b + 5);                 // block gate open
        vm.prank(ALICE);
        vm.expectRevert(liquidity_locker.still_locked.selector);
        lk.withdraw(id);
    }

    function test_attack_BothGatesPassedOpens() public {
        uint48 t = uint48(block.timestamp + 30 days);
        uint40 b = uint40(block.number + 1000);
        vm.prank(ALICE);
        uint256 id = lk.lock_until(address(tok), AMT, t, b, ALICE);
        vm.warp(t); vm.roll(b);
        vm.prank(ALICE);
        lk.withdraw(id);
    }

    // ─────────────────────────────────────────────── 4. extend-only
    function test_attack_CannotShortenViaExtend() public {
        uint48 t = uint48(block.timestamp + 365 days);
        uint256 id = _lock(t);
        vm.prank(ALICE);
        vm.expectRevert(liquidity_locker.not_shortenable.selector);
        lk.extend(id, t - 1);
    }

    function test_attack_CannotShortenViaEqualExtend() public {
        uint48 t = uint48(block.timestamp + 365 days);
        uint256 id = _lock(t);
        vm.prank(ALICE);
        vm.expectRevert(liquidity_locker.not_shortenable.selector);
        lk.extend(id, t);                       // equal is not an extension
    }

    function test_attack_CannotShortenViaZeroExtendBy() public {
        uint256 id = _lock(uint48(block.timestamp + 365 days));
        vm.prank(ALICE);
        vm.expectRevert(liquidity_locker.not_shortenable.selector);
        lk.extend_by(id, 0);
    }

    function test_attack_ExtendByAddsToMaturityNotToNow() public {
        uint48 t = uint48(block.timestamp + 365 days);
        uint256 id = _lock(t);
        vm.warp(block.timestamp + 300 days);    // extend LATE
        vm.prank(ALICE);
        lk.extend_by(id, 30 days);
        (uint48 unlock_at, ) = lk.gates_of(id);
        assertEq(unlock_at, t + 30 days, "extending late silently shortened the lock");
    }

    function test_attack_CannotShortenTheBlockGate() public {
        uint40 b = uint40(block.number + 100_000);
        vm.prank(ALICE);
        uint256 id = lk.lock_until(address(tok), AMT, 0, b, ALICE);
        vm.prank(ALICE);
        vm.expectRevert(liquidity_locker.not_shortenable.selector);
        lk.extend_block(id, b - 1);
    }

    /// Extending must not become a way to shorten by wrapping the type.
    /// Just past the uint48 horizon the contract's own named guard fires.
    function test_attack_ExtendByPastTheTypeHorizonIsNamed() public {
        uint256 id = _lock(uint48(block.timestamp + 365 days));
        vm.prank(ALICE);
        vm.expectRevert(liquidity_locker.timestamp_overflow.selector);
        lk.extend_by(id, uint256(type(uint48).max));
    }

    /// FINDING (informational, no severity): at absurd inputs the checked add in
    /// `extend_by` panics (0x11) BEFORE `timestamp_overflow()` can be reached, so the
    /// named error is unreachable there and the caller sees a bare panic. The SECURITY
    /// property is unaffected — it still reverts, nothing wraps, no lock is shortened —
    /// so this is asserted as "reverts, somehow", which is all the vault must guarantee.
    function test_attack_ExtendByAtUintMaxStillReverts() public {
        uint48 t = uint48(block.timestamp + 365 days);
        uint256 id = _lock(t);
        vm.prank(ALICE);
        vm.expectRevert();                       // panic 0x11 today; either way, no wrap
        lk.extend_by(id, type(uint256).max);
        (uint48 unlock_at, ) = lk.gates_of(id);
        assertEq(unlock_at, t, "maturity moved on a reverted extend");
    }

    function test_attack_ExtendBlockByPastTheTypeHorizonIsNamed() public {
        uint40 b = uint40(block.number + 1000);
        vm.prank(ALICE);
        uint256 id = lk.lock_until(address(tok), AMT, 0, b, ALICE);
        vm.prank(ALICE);
        vm.expectRevert(liquidity_locker.timestamp_overflow.selector);
        lk.extend_block_by(id, uint256(type(uint40).max));
    }

    function test_attack_ExtendBlockByAtUintMaxStillReverts() public {
        uint40 b = uint40(block.number + 1000);
        vm.prank(ALICE);
        uint256 id = lk.lock_until(address(tok), AMT, 0, b, ALICE);
        vm.prank(ALICE);
        vm.expectRevert();
        lk.extend_block_by(id, type(uint256).max);
        (, uint40 unlock_block) = lk.gates_of(id);
        assertEq(unlock_block, b, "the block gate moved on a reverted extend");
    }

    // ─────────────────────────────────────────────── 5. authority
    function test_attack_StrangerCannotWithdraw() public {
        uint48 t = uint48(block.timestamp + 1 days);
        uint256 id = _lock(t);
        vm.warp(t);
        vm.prank(MALLORY);
        vm.expectRevert(liquidity_locker.not_beneficiary.selector);
        lk.withdraw(id);
    }

    function test_attack_StrangerCannotRedirectPayout() public {
        uint48 t = uint48(block.timestamp + 1 days);
        uint256 id = _lock(t);
        vm.warp(t);
        vm.prank(MALLORY);
        vm.expectRevert(liquidity_locker.not_beneficiary.selector);
        lk.withdraw_to(id, MALLORY);
    }

    function test_attack_StrangerCannotExtendOrAssign() public {
        uint256 id = _lock(uint48(block.timestamp + 365 days));
        vm.prank(MALLORY);
        vm.expectRevert(liquidity_locker.not_beneficiary.selector);
        lk.extend(id, uint48(block.timestamp + 400 days));
        vm.prank(MALLORY);
        vm.expectRevert(liquidity_locker.not_beneficiary.selector);
        lk.assign(id, MALLORY);
    }

    function test_attack_CannotWithdrawTwice() public {
        uint48 t = uint48(block.timestamp + 1 days);
        uint256 id = _lock(t);
        vm.warp(t);
        vm.startPrank(ALICE);
        lk.withdraw(id);
        vm.expectRevert(liquidity_locker.already_withdrawn.selector);
        lk.withdraw(id);
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────── 6. succession
    function test_attack_OldBeneficiaryLosesTheKeyOnAssign() public {
        uint48 t = uint48(block.timestamp + 1 days);
        uint256 id = _lock(t);
        vm.prank(ALICE);
        lk.assign(id, MALLORY);
        vm.warp(t);
        vm.prank(ALICE);
        vm.expectRevert(liquidity_locker.not_beneficiary.selector);
        lk.withdraw(id);                        // assign must move the key, not copy it
    }

    function test_attack_AssignDoesNotMoveMaturity() public {
        uint48 t = uint48(block.timestamp + 365 days);
        uint256 id = _lock(t);
        vm.prank(ALICE);
        lk.assign(id, MALLORY);
        vm.prank(MALLORY);
        vm.expectRevert(liquidity_locker.still_locked.selector);
        lk.withdraw(id);                        // succession is not an early exit
    }

    function test_attack_CannotAssignToZeroAndStrand() public {
        uint256 id = _lock(uint48(block.timestamp + 1 days));
        vm.prank(ALICE);
        vm.expectRevert(liquidity_locker.zero_address.selector);
        lk.assign(id, address(0));
    }

    // ─────────────────────────────────────────────── 7. re-entrancy
    function test_attack_ReentrantTokenCannotDoubleWithdraw() public {
        reentrant_token rt = new reentrant_token();
        rt.mint(ALICE, AMT);
        vm.prank(ALICE);
        rt.approve(address(lk), type(uint256).max);
        uint48 t = uint48(block.timestamp + 1 days);
        vm.prank(ALICE);
        uint256 id = lk.lock(address(rt), AMT, t, ALICE);
        rt.arm(lk, id);
        vm.warp(t);
        vm.prank(ALICE);
        vm.expectRevert();                      // the mutex, or already_withdrawn
        lk.withdraw(id);
    }

    // ─────────────────────────────────────────────── 8. arithmetic / horizon
    function test_attack_CannotLockPastTheHorizon() public {
        vm.prank(ALICE);
        vm.expectRevert(liquidity_locker.duration_too_long.selector);
        lk.lock(address(tok), AMT, type(uint48).max, ALICE);
    }

    function test_attack_CannotLockInThePast() public {
        vm.prank(ALICE);
        vm.expectRevert(liquidity_locker.bad_unlock_time.selector);
        lk.lock(address(tok), AMT, uint48(block.timestamp - 1), ALICE);
    }

    /// The sweep is permissionless. It must never be able to reach locked principal,
    /// no matter who calls it or when.
    function test_attack_SweepCannotReachLockedPrincipal() public {
        uint48 t = uint48(block.timestamp + 365 days);
        uint256 id = _lock(t);
        vm.prank(MALLORY);
        vm.expectRevert(liquidity_locker.nothing_to_sweep.selector);
        lk.sweep_surplus(address(tok));
        assertEq(tok.balanceOf(address(lk)), AMT, "the sweep moved locked principal");
        vm.warp(t);
        vm.prank(ALICE);
        lk.withdraw(id);
        assertEq(tok.balanceOf(ALICE), 10 * AMT, "principal did not survive the sweep attempt");
    }

}
