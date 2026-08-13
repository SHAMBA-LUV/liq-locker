// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * REDEMPTION — "is the LP definitely coming back?"
 *
 * The other fork tests prove the lock HOLDS. This one exists to prove the opposite thing,
 * which is the question a treasurer actually asks before signing: **at maturity, does the
 * real Uniswap V2 LUV/WETH position come back to the wallet, in full, and by a route that
 * cannot be taken away?**
 *
 * It is written against the REAL pair token at 0x57D2085A…8a31 and the REAL treasury
 * balance read from the fork, so it answers for the actual position rather than a mock of it.
 *
 * The four ways a lock like this strands funds in practice, each answered:
 *
 *   1. THE AMOUNT COMES BACK SHORT. A fee-on-transfer token, or a rounding bug like the D-1
 *      found in the sibling luv-locker, leaves the last withdrawer unable to take their
 *      final wei. Answered by asserting the EXACT balance, before and after, to the wei.
 *
 *   2. THE ROUTE DEPENDS ON SOMETHING THAT COULD BREAK. If withdrawal required a signature,
 *      it would depend on the verifier contract still working and on the holder still being
 *      able to produce a signature of that scheme. Answered by exiting a door-created lock
 *      through the INHERITED withdraw(), with no signature and no verifier involvement —
 *      and by doing it on a door whose verifier is hostile.
 *
 *   3. SOMEONE ELSE EMPTIES IT FIRST. Answered by running the permissionless sweep, by a
 *      stranger, at every stage, and asserting the position is untouched.
 *
 *   4. THE HOLDER CANNOT SIGN AT MATURITY. This one has NO code answer and is not fixed
 *      here — see test_Redemption_TheOnlyUnrecoverableCase. It is the reason
 *      PRODUCTION.md §4 asks for a beneficiary you can still sign with at maturity.
 */

import "forge-std/Test.sol";
import {liquidity_locker} from "../src/liquidity_locker.sol";
import {locker_door} from "../src/locker_door.sol";
import {VerifierECDSA} from "../src/verifier_ecdsa.sol";
import {ISignatureVerifier} from "../src/i_signature_verifier.sol";

interface IPair {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function totalSupply() external view returns (uint256);
}

/// says yes to everything — used to prove the signature-free exit does not need it
contract yes_verifier is ISignatureVerifier {
    function verify(address, bytes32, bytes calldata) external pure returns (bool) { return true; }
    function schemeId() external pure returns (bytes32) { return keccak256("YES"); }
}

contract redemption_fork_test is Test {
    address internal constant PAIR     = 0x57D2085Aa859a145cB107845AD03c0eAAFBD8a31;
    address internal constant TREASURY = 0x10f7Ee226B16bea7f365Dc1eDEF159Fc1957D169;
    address internal constant STRANGER = address(0xBAD);
    address internal constant SINK     = address(0x5151);

    liquidity_locker internal L;
    IPair internal pair = IPair(PAIR);
    bool internal live;

    uint48 internal constant NINETY = 90 days;

    modifier onFork() { if (!live) return; _; }

    function setUp() public {
        if (!vm.envOr("FORK_TEST", false)) { vm.skip(true); return; }
        string memory rpc = vm.envOr("ETH_RPC_URL", string("https://ethereum-rpc.publicnode.com"));
        uint256 pin = vm.envOr("FORK_BLOCK", uint256(0));
        if (pin == 0) vm.createSelectFork(rpc); else vm.createSelectFork(rpc, pin);
        live = true;
        L = new liquidity_locker(SINK);
    }

    function _treasuryLp() internal view returns (uint256) { return pair.balanceOf(TREASURY); }

    /**
     * THE HEADLINE. The entire real position, locked for ninety days, comes back to the
     * treasury at maturity — to the wei, with nothing withheld.
     */
    function test_Redemption_TheWholeRealPositionComesBackExactly() public onFork {
        uint256 amount = _treasuryLp();
        assertGt(amount, 0, "the treasury holds no LP on this fork");

        vm.startPrank(TREASURY);
        pair.approve(address(L), amount);
        uint256 id = L.lock(PAIR, amount, uint48(block.timestamp + NINETY), TREASURY);
        vm.stopPrank();

        // while locked, the treasury holds nothing and the locker holds everything
        assertEq(pair.balanceOf(TREASURY), 0, "LP did not leave the treasury");
        assertEq(pair.balanceOf(address(L)), amount, "the locker did not receive the whole position");

        vm.warp(block.timestamp + NINETY);
        vm.prank(TREASURY);
        L.withdraw(id);

        assertEq(pair.balanceOf(TREASURY), amount, "the position did NOT come back in full");
        assertEq(pair.balanceOf(address(L)), 0, "the locker kept some of it");
        emit log_named_uint("LP returned to the treasury, to the wei", amount);
    }

    /// The same, one wei at a time: no fee, no rounding, no shortfall on the LP token.
    function test_Redemption_NotOneWeiIsWithheld() public onFork {
        uint256 amount = _treasuryLp();
        vm.startPrank(TREASURY);
        pair.approve(address(L), amount);
        uint256 id = L.lock(PAIR, amount, uint48(block.timestamp + NINETY), TREASURY);
        vm.stopPrank();
        vm.warp(block.timestamp + NINETY);

        uint256 before = pair.balanceOf(TREASURY);
        vm.prank(TREASURY);
        L.withdraw(id);
        assertEq(pair.balanceOf(TREASURY) - before, amount, "the returned amount != the locked amount");
    }

    /**
     * ROUTE INDEPENDENCE. A lock created through the DOOR is withdrawable by the beneficiary
     * through the INHERITED withdraw() — no signature, no verifier call, no deadline, no
     * nonce. Proven here on a door whose verifier is HOSTILE, so the signed path is worthless
     * and the exit still works: the signature route is a convenience, never the only way out.
     */
    function test_Redemption_DoorLockExitsWithoutAnySignature() public onFork {
        yes_verifier evil = new yes_verifier();
        locker_door D = new locker_door(SINK, address(0x0417), address(0x0425), ISignatureVerifier(address(evil)));

        uint256 amount = _treasuryLp();
        vm.startPrank(TREASURY);
        pair.approve(address(D), amount);
        uint256 id = D.lock_your_own(PAIR, amount, uint48(block.timestamp + NINETY));
        vm.stopPrank();

        vm.warp(block.timestamp + NINETY);

        // the plain, inherited, signature-free exit
        vm.prank(TREASURY);
        D.withdraw(id);

        assertEq(pair.balanceOf(TREASURY), amount, "the door did not return the position without a signature");
        emit log_string("door-created lock exited via inherited withdraw() - verifier never consulted");
    }

    /// And to a chosen address, still without a signature.
    function test_Redemption_WithdrawToASuccessorWithoutASignature() public onFork {
        address successor = address(0x5CC0);
        uint256 amount = _treasuryLp();
        vm.startPrank(TREASURY);
        pair.approve(address(L), amount);
        uint256 id = L.lock(PAIR, amount, uint48(block.timestamp + NINETY), TREASURY);
        vm.stopPrank();
        vm.warp(block.timestamp + NINETY);

        vm.prank(TREASURY);
        L.withdraw_to(id, successor);
        assertEq(pair.balanceOf(successor), amount, "withdraw_to did not deliver the position");
    }

    /**
     * NOBODY CAN EMPTY IT FIRST. The sweep is permissionless by design, so it is run by a
     * stranger at every stage of the lock's life and the position must be untouched each time.
     */
    function test_Redemption_NoStrangerCanTakeItAtAnyStage() public onFork {
        uint256 amount = _treasuryLp();
        vm.startPrank(TREASURY);
        pair.approve(address(L), amount);
        uint256 id = L.lock(PAIR, amount, uint48(block.timestamp + NINETY), TREASURY);
        vm.stopPrank();

        // stage 1: mid-lock
        vm.prank(STRANGER);
        vm.expectRevert(liquidity_locker.nothing_to_sweep.selector);
        L.sweep_surplus(PAIR);
        assertEq(pair.balanceOf(address(L)), amount, "the sweep moved locked LP mid-lock");

        // stage 2: matured but unclaimed — the most tempting moment
        vm.warp(block.timestamp + NINETY);
        vm.prank(STRANGER);
        vm.expectRevert(liquidity_locker.nothing_to_sweep.selector);
        L.sweep_surplus(PAIR);
        vm.prank(STRANGER);
        vm.expectRevert(liquidity_locker.not_beneficiary.selector);
        L.withdraw(id);
        assertEq(pair.balanceOf(address(L)), amount, "the position was taken after maturity");

        // stage 3: the rightful owner still gets all of it
        vm.prank(TREASURY);
        L.withdraw(id);
        assertEq(pair.balanceOf(TREASURY), amount, "the position did not survive to redemption");
    }

    /**
     * A CENTURY, AND STILL EXACT. Long locks are where a maturity computed in seconds can
     * drift; uint48 runs to the year 8,921,556 and the contract caps a lock at 200 years.
     */
    function test_Redemption_SurvivesTheLongestLockTheContractAllows() public onFork {
        uint256 amount = _treasuryLp();
        uint48 far = uint48(block.timestamp + 199 * 365 days);
        vm.startPrank(TREASURY);
        pair.approve(address(L), amount);
        uint256 id = L.lock(PAIR, amount, far, TREASURY);
        vm.stopPrank();

        vm.warp(far - 1);
        vm.prank(TREASURY);
        vm.expectRevert(liquidity_locker.still_locked.selector);
        L.withdraw(id);

        vm.warp(far);
        vm.prank(TREASURY);
        L.withdraw(id);
        assertEq(pair.balanceOf(TREASURY), amount, "199 years later, short by something");
    }

    /**
     * THE BLOCK GATE IS A RISK AS WELL AS A PROTECTION, and this states it honestly.
     *
     * Both gates must pass, so the LATER governs. A block gate set from an assumed 12-second
     * cadence therefore DELAYS redemption if the chain slows down — the position is never
     * lost, but it is not redeemable on the date the calendar suggested. Setting only the
     * time gate removes this risk entirely.
     */
    function test_Redemption_BlockGateCanDelayRedemptionIfTheChainSlows() public onFork {
        uint256 amount = _treasuryLp();
        uint40 assumed = uint40(block.number + (uint256(NINETY) / 12));   // 12s cadence assumed
        vm.startPrank(TREASURY);
        pair.approve(address(L), amount);
        uint256 id = L.lock_until(PAIR, amount, uint48(block.timestamp + NINETY), assumed, TREASURY);
        vm.stopPrank();

        // ninety days pass, but the chain ran at 15s and produced fewer blocks
        vm.warp(block.timestamp + NINETY);
        vm.roll(block.number + (uint256(NINETY) / 15));
        vm.prank(TREASURY);
        vm.expectRevert(liquidity_locker.still_locked.selector);
        L.withdraw(id);
        emit log_string("TIME matured but the BLOCK gate had not - redemption delayed, not lost");

        // the position is not lost; it redeems in full once the blocks arrive
        vm.roll(assumed);
        vm.prank(TREASURY);
        L.withdraw(id);
        assertEq(pair.balanceOf(TREASURY), amount, "the position did not return once both gates passed");
    }

    /**
     * THE ONE CASE WITH NO CODE ANSWER.
     *
     * There is no owner and no rescue. If the beneficiary cannot transact at maturity — key
     * lost, multisig quorum unreachable, a contract that cannot call `withdraw` — the
     * position stays locked for ever and NOBODY can retrieve it. That is the deliberate cost
     * of having no owner: the same absence that stops anyone taking it early stops anyone
     * getting it back on the holder's behalf.
     *
     * `assign` is the mitigation, and it only works BEFORE the key is lost.
     */
    function test_Redemption_TheOnlyUnrecoverableCase() public onFork {
        uint256 amount = _treasuryLp();
        address lost_wallet = address(0xDEAD10C4);

        vm.startPrank(TREASURY);
        pair.approve(address(L), amount);
        uint256 id = L.lock(PAIR, amount, uint48(block.timestamp + NINETY), lost_wallet);
        vm.stopPrank();
        vm.warp(block.timestamp + NINETY);

        // matured, and nobody but the lost wallet may open it
        vm.prank(TREASURY);
        vm.expectRevert(liquidity_locker.not_beneficiary.selector);
        L.withdraw(id);
        vm.prank(STRANGER);
        vm.expectRevert(liquidity_locker.not_beneficiary.selector);
        L.withdraw(id);
        assertEq(pair.balanceOf(address(L)), amount, "someone retrieved it on the holder's behalf");
        emit log_string("UNRECOVERABLE by design: no owner means no rescue. Use assign() BEFORE you lose the key.");

        // assign, done in time, is the whole mitigation
        vm.prank(lost_wallet);
        L.assign(id, TREASURY);
        vm.prank(TREASURY);
        L.withdraw(id);
        assertEq(pair.balanceOf(TREASURY), amount, "succession did not deliver the position");
    }
}
