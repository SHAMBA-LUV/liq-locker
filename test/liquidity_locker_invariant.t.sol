// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.0;

import "forge-std/Test.sol";
import {liquidity_locker} from "../src/liquidity_locker.sol";
import {mock_erc20} from "./mocks.sol";

/**
 * Stateful invariant fuzzing — AUDIT §5, the highest-value missing test, now written.
 *
 * The unit suites check properties one operation at a time, against sequences a human
 * chose. This drives the vault with RANDOM sequences of every mutating operation — lock,
 * lock_default, lock_for, lock_until, extend, extend_by, extend_default, extend_block,
 * assign, withdraw, redeem_interest, sweep_surplus — interleaved with random reflections
 * and random advances of BOTH clocks, and asserts after every step that the properties
 * which make this thing a lock still hold.
 *
 * The four that matter:
 *   1. SOLVENCY        — the vault always holds at least what it owes.
 *   2. BOOKS AGREE     — total_locked equals the sum of live principal, exactly.
 *   3. GATES ARE ONE-WAY — no gate on any lock ever moved backwards, under any sequence.
 *   4. NO EARLY EXIT   — nothing was ever withdrawn while either of its gates still held.
 *
 * (3) and (4) are the security claims. They are checked against ghost state recorded by
 * the handler at call time, not re-derived from the contract, so a bug that rewrote a gate
 * could not hide from them.
 */
contract handler is Test {
    liquidity_locker public L;
    mock_erc20 public lp;

    address[3] public actors = [address(0xA11CE), address(0xDA0), address(0xB0B)];

    uint256 public T; // absolute time cursor (AUDIT T-1: never chain warps)
    uint256 public B; // absolute block cursor

    // ── ghosts ──
    uint256 public ghost_live_principal;
    uint256 public ghost_early_exits; // must stay 0
    uint256 public ghost_gate_reversals; // must stay 0
    uint256 public ghost_locks;
    uint256 public ghost_withdrawals;
    uint256 public ghost_extensions;
    mapping(uint256 => uint48) public ghost_max_at;
    mapping(uint256 => uint40) public ghost_max_block;
    mapping(uint256 => uint256) public ghost_principal;
    mapping(uint256 => bool) public ghost_closed;
    uint256[] public ids;

    constructor(liquidity_locker L_, mock_erc20 lp_, uint256 t0, uint256 b0) {
        L = L_;
        lp = lp_;
        T = t0;
        B = b0;
        for (uint256 i; i < actors.length; i++) {
            lp.mint(actors[i], 1_000_000 ether);
            vm.prank(actors[i]);
            lp.approve(address(L), type(uint256).max);
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    /// Record the gates now, and flag any that went backwards since we last looked.
    function _observe(uint256 id) internal {
        (uint48 at, uint40 blk) = L.gates_of(id);
        if (at < ghost_max_at[id] || blk < ghost_max_block[id]) ghost_gate_reversals++;
        if (at > ghost_max_at[id]) ghost_max_at[id] = at;
        if (blk > ghost_max_block[id]) ghost_max_block[id] = blk;
    }

    function _observeAll() internal {
        for (uint256 i; i < ids.length; i++) {
            if (!ghost_closed[ids[i]]) _observe(ids[i]);
        }
    }

    // ───────────────────────── the operations ─────────────────────────

    function lock_default(uint256 seed, uint256 amount) public {
        address a = _actor(seed);
        amount = bound(amount, 1, 10_000 ether);
        if (lp.balanceOf(a) < amount) return;
        vm.prank(a);
        uint256 id = L.lock_default(address(lp), amount, address(0));
        _register(id, amount);
    }

    function lock_for(uint256 seed, uint256 amount, uint256 duration) public {
        address a = _actor(seed);
        amount = bound(amount, 1, 10_000 ether);
        duration = bound(duration, 1, L.MAX_LOCK_DURATION());
        if (lp.balanceOf(a) < amount) return;
        vm.prank(a);
        uint256 id = L.lock_for(address(lp), amount, duration, address(0));
        _register(id, amount);
    }

    function lock_until(uint256 seed, uint256 amount, uint256 secs, uint256 blks) public {
        address a = _actor(seed);
        amount = bound(amount, 1, 10_000 ether);
        secs = bound(secs, 0, 40 * 365 days);
        blks = bound(blks, 0, 5_000_000);
        if (secs == 0 && blks == 0) secs = 1 days; // a lock needs at least one gate
        if (lp.balanceOf(a) < amount) return;
        vm.prank(a);
        uint256 id = L.lock_until(
            address(lp),
            amount,
            secs == 0 ? uint48(0) : uint48(T + secs),
            blks == 0 ? uint40(0) : uint40(B + blks),
            address(0)
        );
        _register(id, amount);
    }

    function _register(uint256 id, uint256 amount) internal {
        ids.push(id);
        ghost_principal[id] = amount; // measured deltas: the mock takes no fee
        ghost_live_principal += amount;
        ghost_locks++;
        _observe(id);
    }

    function extend_default(uint256 which) public {
        (uint256 id, address who) = _pick(which);
        if (who == address(0)) return;
        vm.prank(who);
        try L.extend_default(id) { ghost_extensions++; } catch {}
        _observeAll();
    }

    function extend_by(uint256 which, uint256 extra) public {
        (uint256 id, address who) = _pick(which);
        if (who == address(0)) return;
        extra = bound(extra, 1, 10 * 365 days);
        vm.prank(who);
        try L.extend_by(id, extra) { ghost_extensions++; } catch {}
        _observeAll();
    }

    function extend_block_by(uint256 which, uint256 extra) public {
        (uint256 id, address who) = _pick(which);
        if (who == address(0)) return;
        extra = bound(extra, 1, 1_000_000);
        vm.prank(who);
        try L.extend_block_by(id, extra) { ghost_extensions++; } catch {}
        _observeAll();
    }

    function assign(uint256 which, uint256 toSeed) public {
        (uint256 id, address who) = _pick(which);
        if (who == address(0)) return;
        vm.prank(who);
        try L.assign(id, _actor(toSeed)) {} catch {}
        _observeAll();
    }

    function withdraw(uint256 which) public {
        (uint256 id, address who) = _pick(which);
        if (who == address(0)) return;
        // What the gates say BEFORE the attempt — the honest record for invariant 4.
        (uint48 at, uint40 blk) = L.gates_of(id);
        bool held = block.timestamp < at || block.number < blk;
        vm.prank(who);
        try L.withdraw(id) {
            if (held) ghost_early_exits++; // it opened while a gate still held
            ghost_closed[id] = true;
            ghost_live_principal -= ghost_principal[id];
            ghost_withdrawals++;
        } catch {}
        _observeAll();
    }

    function redeem(uint256 which) public {
        (uint256 id, address who) = _pick(which);
        if (who == address(0)) return;
        vm.prank(who);
        try L.redeem_interest(id) {} catch {}
        _observeAll();
    }

    function sweep() public {
        try L.sweep_surplus(address(lp)) {} catch {}
        _observeAll();
    }

    /// A reflection: balance arrives from nowhere, exactly as a fee-share token does.
    function reflect(uint256 amount) public {
        amount = bound(amount, 1, 1_000 ether);
        lp.mint(address(L), amount);
        _observeAll();
    }

    function warp(uint256 secs) public {
        T += bound(secs, 1, 200 days);
        vm.warp(T);
        _observeAll();
    }

    function roll(uint256 blocks_) public {
        B += bound(blocks_, 1, 1_000_000);
        vm.roll(B);
        _observeAll();
    }

    function _pick(uint256 which) internal view returns (uint256 id, address who) {
        if (ids.length == 0) return (0, address(0));
        id = ids[which % ids.length];
        if (ghost_closed[id]) return (id, address(0));
        (, address beneficiary,,,) = L.lock_at(id);
        who = beneficiary;
    }

    function idCount() external view returns (uint256) {
        return ids.length;
    }
}

contract liquidity_locker_invariant_test is Test {
    liquidity_locker internal L;
    mock_erc20 internal lp;
    handler internal H;

    address internal sink = address(0x5142);

    function setUp() public {
        vm.warp(1_800_000_000);
        vm.roll(21_000_000);
        L = new liquidity_locker(sink);
        lp = new mock_erc20();
        H = new handler(L, lp, 1_800_000_000, 21_000_000);
        targetContract(address(H));
    }

    /// 1. SOLVENCY. The vault holds at least the principal it owes, always.
    function invariant_BalanceCoversLockedPrincipal() public view {
        assertGe(lp.balanceOf(address(L)), L.total_locked(address(lp)), "insolvent");
    }

    /// 1b. And at least principal + the interest it has already promised.
    function invariant_BalanceCoversPrincipalPlusPromised() public view {
        assertGe(
            lp.balanceOf(address(L)),
            L.total_locked(address(lp)) + L.promised(address(lp)),
            "promised more than held"
        );
    }

    /// 2. BOOKS AGREE. total_locked is exactly the sum of live principal.
    function invariant_TotalLockedEqualsLivePrincipal() public view {
        assertEq(L.total_locked(address(lp)), H.ghost_live_principal(), "books drifted");
    }

    /// 3. GATES ARE ONE-WAY. No gate on any lock ever moved backwards.
    function invariant_NoGateEverMovedBackwards() public view {
        assertEq(H.ghost_gate_reversals(), 0, "a gate was shortened");
    }

    /// 4. NO EARLY EXIT. Nothing was ever withdrawn while either gate still held.
    function invariant_NothingLeftEarly() public view {
        assertEq(H.ghost_early_exits(), 0, "a lock opened early");
    }

    /// The sink can never be paid out of locked principal.
    function invariant_SinkNeverHoldsLockedPrincipal() public view {
        assertLe(lp.balanceOf(sink), lp.totalSupply() - L.total_locked(address(lp)), "sink ate principal");
    }

    /**
     * A run that never locked anything proves nothing. This must NOT be an invariant:
     * invariants are evaluated at set-up too, before the fuzzer has called anything, where
     * zero locks is the correct state. `afterInvariant` runs once each sequence completes,
     * which is where "did this run actually exercise the vault" is a fair question to ask.
     */
    function afterInvariant() public view {
        assertGt(H.ghost_locks(), 0, "no locks were created in this run");
        assertGt(H.ghost_withdrawals() + H.ghost_extensions(), 0, "nothing was extended or withdrawn");
    }
}
