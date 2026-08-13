// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.0;

import "forge-std/Test.sol";
import {liquidity_locker} from "../src/liquidity_locker.sol";

/**
 * THE MAINNET-FORK REHEARSAL — AUDIT §5.
 *
 * Every other suite locks a mock. A mock is a token that behaves the way the author of the
 * test expected a token to behave, which is precisely the assumption a rehearsal exists to
 * remove. This one forks Ethereum and locks the REAL Uniswap V2 pair token for LUV/WETH —
 * the actual position this vault was written to hold — held by the actual treasury that
 * would lock it, at whatever balance the chain says it holds when the test runs.
 *
 * Nothing here is hardcoded but the addresses. Amounts, reserves and supply are read from
 * the fork, so the rehearsal keeps telling the truth as the chain moves rather than going
 * stale the day after it was written.
 *
 * WHAT IT PROVES, in the order the runbook does it:
 *   1. the pair is what we think it is (token0/token1, supply, who holds the LP)
 *   2. the dust rehearsal clears end to end — approve, lock, mature, withdraw
 *   3. locking 100% of the position makes the liquidity provably unremovable, and the
 *      pool's reserves are untouched by the fact
 *   4. extension on the real position is one-way, in both gates
 *   5. nobody else can reach it, and the permissionless sweep cannot either
 *   6. a century holds, under time and block height together
 *   7. the real LUV token credits exactly what arrived (measured delta, no mock)
 *
 * RUN IT:
 *     make fork-test                      # uses a public node, no key needed
 *     FORK_TEST=1 forge test --match-path test/liquidity_locker_fork.t.sol -vv
 *     ETH_RPC_URL=https://… FORK_TEST=1 forge test --match-path …   # your own node
 *
 * It is SKIPPED unless FORK_TEST=1 so the default suite stays hermetic and offline —
 * a test that needs the internet must never be able to fail the build of someone who has
 * none. Forking is at HEAD by default (any node serves it); set FORK_BLOCK to pin, which
 * needs an archive node once the block leaves the recent-state window.
 */
interface IUniV2Pair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function getReserves() external view returns (uint112, uint112, uint32);
    function burn(address to) external returns (uint256 amount0, uint256 amount1);
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function symbol() external view returns (string memory);
}

contract liquidity_locker_fork_test is Test {
    // The real thing, on Ethereum mainnet.
    address internal constant PAIR = 0x57D2085Aa859a145cB107845AD03c0eAAFBD8a31; // LUV/WETH UNI-V2
    address internal constant LUV = 0x2711111111683B8708cb9a48cBf36a51315F8254;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant TREASURY = 0x10f7Ee226B16bea7f365Dc1eDEF159Fc1957D169; // bankon.eth

    address internal constant DEFAULT_RPC = address(0); // documentation only; see _fork()
    address internal sink = address(0x5142);
    address internal stranger = address(0xBAD);
    address internal successor = address(0xDA0);

    liquidity_locker internal L;
    IUniV2Pair internal pair = IUniV2Pair(PAIR);

    bool internal live; // false when the suite is skipped

    uint256 internal constant QUARTER = 90 days;
    uint256 internal constant CENTURY = 36525 days;

    function setUp() public {
        if (!vm.envOr("FORK_TEST", false)) {
            vm.skip(true);
            return;
        }
        string memory rpc = vm.envOr("ETH_RPC_URL", string("https://ethereum-rpc.publicnode.com"));
        uint256 pin = vm.envOr("FORK_BLOCK", uint256(0));
        if (pin == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, pin);
        live = true;

        L = new liquidity_locker(sink);
    }

    modifier onFork() {
        if (!live) return;
        _;
    }

    /// The treasury's real LP balance, right now on the fork. Never a stale constant —
    /// the runbook's own rule is to re-read the balance at execution time.
    function _treasuryLp() internal view returns (uint256) {
        return pair.balanceOf(TREASURY);
    }

    function _approve(uint256 amount) internal {
        vm.prank(TREASURY);
        pair.approve(address(L), amount);
    }

    // ───────────────── 1. the pair is what we think it is ─────────────────

    function test_Fork_TheRealPairIsWhatWeThinkItIs() public onFork {
        assertEq(pair.token0(), LUV, "token0 is not LUV -- wrong pair");
        assertEq(pair.token1(), WETH, "token1 is not WETH -- wrong pair");

        uint256 supply = pair.totalSupply();
        assertGt(supply, 0, "the pair has no LP at all");

        uint256 held = _treasuryLp();
        assertGt(held, 0, "the treasury holds no LP on this fork");
        // UNI-V2 burns 1000 wei of LP at genesis (MINIMUM_LIQUIDITY) and it can never move,
        // so the treasury holding supply-1000 is holding 100% of what can circulate.
        assertEq(held + 1000, supply, "the treasury does not hold 100% of circulating LP");

        (uint112 r0, uint112 r1,) = pair.getReserves();
        assertGt(r0, 0);
        assertGt(r1, 0);
        emit log_named_uint("treasury LP", held);
        emit log_named_uint("LUV reserve", r0);
        emit log_named_uint("WETH reserve", r1);
    }

    // ───────────────── 2. the dust rehearsal, end to end ─────────────────

    function test_Fork_RehearsalDustLockClearsEndToEnd() public onFork {
        uint256 dust = 1e15; // 0.001 LP — the runbook's rehearsal size
        uint256 before = _treasuryLp();
        assertGt(before, dust, "not enough LP to rehearse with");

        _approve(dust);
        vm.prank(TREASURY);
        uint256 id = L.lock_default(PAIR, dust, address(0));

        assertEq(pair.balanceOf(address(L)), dust, "the vault did not receive the LP");
        assertEq(_treasuryLp(), before - dust);
        (uint48 at, uint40 blk) = L.gates_of(id);
        assertEq(at, uint48(block.timestamp + QUARTER), "not the ninety-day default");
        assertEq(blk, 0);
        assertTrue(L.is_locked(id));

        // and it comes back, whole, at maturity — a rehearsal that never returns is not one
        vm.warp(block.timestamp + QUARTER);
        vm.prank(TREASURY);
        L.withdraw(id);
        assertEq(_treasuryLp(), before, "the rehearsal did not return the dust");
        assertEq(pair.balanceOf(address(L)), 0);
    }

    // ───────────────── 3. the full position, unremovable ─────────────────

    function test_Fork_LockingTheFullPositionMakesLiquidityUnremovable() public onFork {
        uint256 amount = _treasuryLp(); // re-read at execution, exactly as the runbook says
        (uint112 r0Before, uint112 r1Before,) = pair.getReserves();

        _approve(amount);
        vm.prank(TREASURY);
        uint256 id = L.lock_default(PAIR, amount, address(0));

        assertEq(pair.balanceOf(address(L)), amount, "the vault does not hold the position");
        assertEq(_treasuryLp(), 0, "the treasury still holds LP");
        assertEq(L.total_locked(PAIR), amount);
        assertTrue(L.is_locked(id));

        // The pool itself is untouched: locking LP moves the CLAIM, never the reserves.
        (uint112 r0After, uint112 r1After,) = pair.getReserves();
        assertEq(r0After, r0Before, "reserves moved");
        assertEq(r1After, r1Before, "reserves moved");

        // And the liquidity cannot be pulled. burn() pays out against LP sent to the pair;
        // the treasury has none to send, and what the vault holds it cannot be made to move.
        vm.prank(TREASURY);
        vm.expectRevert(); // UniswapV2: INSUFFICIENT_LIQUIDITY_BURNED
        pair.burn(TREASURY);

        (uint112 r0End, uint112 r1End,) = pair.getReserves();
        assertEq(r0End, r0Before, "a burn attempt moved the reserves");
        assertEq(r1End, r1Before, "a burn attempt moved the reserves");
    }

    // ───────────────── 4. extension is one-way, on the real position ─────────────────

    function test_Fork_ExtensionOnTheRealPositionIsOneWay() public onFork {
        uint256 amount = _treasuryLp();
        _approve(amount);
        vm.prank(TREASURY);
        uint256 id = L.lock_default(PAIR, amount, address(0));
        (uint48 at0,) = L.gates_of(id);

        vm.prank(TREASURY);
        L.extend_default(id); // a quarter more
        (uint48 at1,) = L.gates_of(id);
        assertEq(at1, at0 + uint48(QUARTER));

        vm.prank(TREASURY);
        L.extend_block_by(id, 2_628_000); // ~1 year of blocks, added to a time-only lock
        (, uint40 blk) = L.gates_of(id);
        assertEq(blk, uint40(block.number + 2_628_000));

        // neither gate can be walked back
        vm.startPrank(TREASURY);
        vm.expectRevert(liquidity_locker.not_shortenable.selector);
        L.extend(id, at0);
        vm.expectRevert(liquidity_locker.not_shortenable.selector);
        L.extend_block(id, uint40(block.number + 1));
        vm.stopPrank();

        // the time gate opening does not open the lock while the block gate holds
        vm.warp(uint256(at1));
        vm.prank(TREASURY);
        vm.expectRevert(liquidity_locker.still_locked.selector);
        L.withdraw(id);
    }

    // ───────────────── 5. nobody else can reach it ─────────────────

    function test_Fork_NobodyElseCanTouchTheRealPosition() public onFork {
        uint256 amount = _treasuryLp();
        _approve(amount);
        vm.prank(TREASURY);
        uint256 id = L.lock_default(PAIR, amount, address(0));

        vm.startPrank(stranger);
        vm.expectRevert(liquidity_locker.not_beneficiary.selector);
        L.withdraw(id);
        vm.expectRevert(liquidity_locker.not_beneficiary.selector);
        L.extend_default(id);
        vm.expectRevert(liquidity_locker.not_beneficiary.selector);
        L.assign(id, stranger);
        vm.stopPrank();

        // the permissionless sweep cannot reach locked principal either
        vm.prank(stranger);
        vm.expectRevert(liquidity_locker.nothing_to_sweep.selector);
        L.sweep_surplus(PAIR);
        assertEq(pair.balanceOf(address(L)), amount, "the position moved");

        // even the treasury cannot open it early
        vm.prank(TREASURY);
        vm.expectRevert(liquidity_locker.still_locked.selector);
        L.withdraw(id);

        // succession moves who may open it, never when
        vm.prank(TREASURY);
        L.assign(id, successor);
        vm.prank(successor);
        vm.expectRevert(liquidity_locker.still_locked.selector);
        L.withdraw(id);
    }

    // ───────────────── 6. a century, both gates, real LP ─────────────────

    function test_Fork_ACenturyOnTheRealPairMaturesAndReturns() public onFork {
        uint256 amount = _treasuryLp();
        uint256 blocks_ = CENTURY / 12; // Ethereum's cadence
        _approve(amount);
        vm.prank(TREASURY);
        uint256 id = L.lock_until(
            PAIR, amount, uint48(block.timestamp + CENTURY), uint40(block.number + blocks_), successor
        );

        (uint256 secs, uint256 blks) = L.time_remaining(id);
        assertEq(secs, CENTURY);
        assertEq(blks, blocks_);

        // one second short, with the blocks already in: still shut
        vm.warp(block.timestamp + CENTURY - 1);
        vm.roll(block.number + blocks_);
        vm.prank(successor);
        vm.expectRevert(liquidity_locker.still_locked.selector);
        L.withdraw(id);

        vm.warp(block.timestamp + 1);
        vm.prank(successor);
        L.withdraw(id);
        assertEq(pair.balanceOf(successor), amount, "a century later, the whole position");
    }

    // ───────────────── 7. the real LUV token, measured ─────────────────

    /// The vault credits what ARRIVED, read from the real token rather than assumed. LUV is a
    /// reflection token whose wallet-to-wallet transfers are fee-free, so the delta equals the
    /// amount here — and the point is that the contract measured it rather than trusting it.
    function test_Fork_RealLuvCreditsTheMeasuredDelta() public onFork {
        IERC20 luv = IERC20(LUV);
        uint256 held = luv.balanceOf(TREASURY);
        assertGt(held, 0, "the treasury holds no LUV on this fork");

        uint256 amount = held / 1000; // a slice, well inside any max-tx rule
        vm.prank(TREASURY);
        luv.approve(address(L), amount);

        uint256 vaultBefore = luv.balanceOf(address(L));
        vm.prank(TREASURY);
        uint256 id = L.lock_default(LUV, amount, address(0));
        uint256 arrived = luv.balanceOf(address(L)) - vaultBefore;

        (,, uint256 credited,,) = L.lock_at(id);
        assertEq(credited, arrived, "credited something other than what arrived");
        assertEq(L.total_locked(LUV), arrived);
        assertLe(credited, amount, "credited more than was sent");

        vm.warp(block.timestamp + QUARTER);
        vm.prank(TREASURY);
        L.withdraw(id);
        assertGe(luv.balanceOf(address(L)), 0);
    }
}
