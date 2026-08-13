// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * THE MALICIOUS VERIFIER — AUDIT §5, item 2.
 *
 *   "A malicious-verifier test: confirm a door with a hostile verifier can forge consent,
 *    so the trust assumption in §3 is demonstrated rather than asserted."
 *
 * This is an UNUSUAL test file, and the shape of it is the point. Everywhere else in this
 * repository a passing test means an attack failed. Here, a passing test means the attack
 * SUCCEEDED — because §3 accepts, in writing, that the verifier is trusted, and an accepted
 * risk that has never been demonstrated is just a sentence.
 *
 * `locker_door` takes an `ISignatureVerifier` in its constructor and asks it whether a
 * signature is good. It is immutable and it is chosen at deploy time. If that address is a
 * contract that returns `true` for everything, then "signed consent" means nothing: anybody
 * can lock anybody's approved tokens, open anybody's lock, and extend anybody's maturity,
 * with a signature of zero bytes.
 *
 * WHAT THIS PROVES, PRECISELY:
 *   1. A hostile verifier forges consent completely — three separate signed paths fall.
 *   2. The blast radius is confined to the DOOR. `liquidity_locker` itself takes no
 *      verifier, so locks made directly against it are untouched by any of this.
 *   3. The choice is verifiable before you trust it: the verifier address is public and
 *      immutable, so a deployed door can be checked once, forever, by anyone.
 *
 * THE OPERATIONAL CONSEQUENCE, which is why this file exists rather than a paragraph:
 * verifying `locker_door` on Etherscan is NOT sufficient to trust it. The door's own source
 * can be flawless while the address it points at is hostile. Whoever audits a deployed door
 * must read `VERIFIER()` and verify THAT contract too. §6's checklist item "Verifier choice
 * made deliberately" is therefore not a formality; it is the entire trust boundary.
 */

import "forge-std/Test.sol";
import {locker_door} from "../src/locker_door.sol";
import {liquidity_locker} from "../src/liquidity_locker.sol";
import {VerifierECDSA} from "../src/verifier_ecdsa.sol";
import {ISignatureVerifier} from "../src/i_signature_verifier.sol";
import {mock_erc20} from "./mocks.sol";

/// Returns true for everything. Forty bytes of malice.
contract yes_verifier is ISignatureVerifier {
    function verify(address, bytes32, bytes calldata) external pure returns (bool) { return true; }
    function schemeId() external pure returns (bytes32) { return keccak256("YES"); }
}

contract malicious_verifier_test is Test {
    locker_door internal honest_door;
    locker_door internal hostile_door;
    liquidity_locker internal bare_locker;
    VerifierECDSA internal good;
    yes_verifier internal evil;
    mock_erc20 internal lp;

    uint256 internal constant VICTIM_PK = 0xC0FFEE;
    address internal victim;
    address internal constant ATTACKER = address(0xBAD);
    address internal constant SINK     = address(0x5151);
    address internal constant OVERLORD = address(0x0417);
    address internal constant OVERSEER = address(0x0425);

    uint48 internal constant YEAR = 365 days;

    function setUp() public {
        vm.warp(1_800_000_000);
        vm.roll(20_000_000);
        victim = vm.addr(VICTIM_PK);

        good = new VerifierECDSA();
        evil = new yes_verifier();
        honest_door  = new locker_door(SINK, OVERLORD, OVERSEER, ISignatureVerifier(address(good)));
        hostile_door = new locker_door(SINK, OVERLORD, OVERSEER, ISignatureVerifier(address(evil)));
        bare_locker  = new liquidity_locker(SINK);

        lp = new mock_erc20();
        lp.mint(victim, 1_000_000 ether);

        // The victim has done nothing wrong: they approved the doors, as any depositor must.
        vm.startPrank(victim);
        lp.approve(address(honest_door), type(uint256).max);
        lp.approve(address(hostile_door), type(uint256).max);
        lp.approve(address(bare_locker), type(uint256).max);
        vm.stopPrank();
    }

    function _now() internal view returns (uint48) { return uint48(block.timestamp); }

    // ─────────────────────────── 1. the honest door refuses the forgery
    /// The control. With the real verifier, a signature from the wrong key is refused.
    function test_HonestDoorRefusesAForgedSignature() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = honest_door.lock_consent_digest(
            address(lp), 1_000 ether, _now() + YEAR, ATTACKER, 0, deadline
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xBADBAD, digest);   // not the victim's key
        vm.prank(ATTACKER);
        vm.expectRevert(locker_door.bad_signer.selector);
        honest_door.lock_with_consent(address(lp), 1_000 ether, _now() + YEAR, victim, deadline, abi.encodePacked(r, s, v));
    }

    // ─────────────────────────── 2. the hostile door forges it perfectly
    /**
     * THE THEFT. This is the one that matters, and it is worth being precise about which
     * call does the damage.
     *
     * `lock_with_consent` pulls from `msg.sender`, so a forged consent there only lets an
     * attacker fund a lock in someone else's name — rude, not theft. `open_door` is the
     * dangerous one: it takes the BENEFICIARY as a parameter and pays out to a `to` the
     * caller chooses, with the signature the only thing standing between them. Hand it a
     * verifier that says yes and the signature stops standing there.
     *
     * Here the victim makes an ordinary, honest lock of their own tokens through the door.
     * The attacker then withdraws it to themselves with an empty signature.
     */
    function test_HostileVerifierForgesAnOpenDoorAndStealsTheLock() public {
        vm.prank(victim);
        uint256 id = hostile_door.lock_your_own(address(lp), 1_000 ether, _now() + 1);
        vm.warp(block.timestamp + 2);          // the victim's lock matures normally

        uint256 attacker_before = lp.balanceOf(ATTACKER);
        vm.prank(ATTACKER);
        hostile_door.open_door(victim, id, ATTACKER, block.timestamp + 1 hours, bytes(hex""));

        assertEq(lp.balanceOf(ATTACKER), attacker_before + 1_000 ether,
            "the forged open did not pay the attacker");
        emit log_string("CONSENT FORGED: the attacker withdrew the victim's matured lock to themselves");
    }

    /// The griefing variant: no theft, but the victim's maturity is moved out nine years.
    function test_HostileVerifierForgesAnExtension() public {
        vm.prank(victim);
        uint256 id = hostile_door.lock_your_own(address(lp), 1_000 ether, _now() + YEAR);

        vm.prank(ATTACKER);
        hostile_door.extend_by_sig(victim, id, _now() + 10 * YEAR, block.timestamp + 1 hours, bytes(hex""));

        (uint48 unlock_at, ) = hostile_door.gates_of(id);
        assertEq(unlock_at, _now() + 10 * YEAR, "the forged extension did not take");
        emit log_string("CONSENT FORGED: the attacker added nine years to the victim's lock");
    }

    /// And consent to be bound at all is forgeable — the attacker funds a lock in the
    /// victim's name without the victim ever signing anything.
    function test_HostileVerifierForgesConsentWithAnEmptySignature() public {
        lp.mint(ATTACKER, 1_000 ether);
        vm.prank(ATTACKER);
        lp.approve(address(hostile_door), type(uint256).max);

        uint256 attacker_before = lp.balanceOf(ATTACKER);
        vm.prank(ATTACKER);
        uint256 id = hostile_door.lock_with_consent(
            address(lp), 1_000 ether, _now() + YEAR, victim, block.timestamp + 1 hours, bytes(hex"")
        );
        // ids begin at 0, so existence is asserted by the effect, not by the number
        assertEq(lp.balanceOf(ATTACKER), attacker_before - 1_000 ether, "no tokens were locked");
        uint256[] memory theirs = hostile_door.locks_of(victim);
        bool bound_to_victim;
        for (uint256 i = 0; i < theirs.length; i++) if (theirs[i] == id) bound_to_victim = true;
        assertTrue(bound_to_victim, "the victim was not made beneficiary");
        emit log_string("CONSENT FORGED: a zero-byte signature bound the victim as beneficiary");
    }

    // ─────────────────────────── 3. the blast radius, bounded
    /**
     * The damage stops at the door. `liquidity_locker` has no verifier and no signed path —
     * its only authority check is `msg.sender == beneficiary`. A hostile verifier cannot
     * reach a lock made directly against the locker, which is what the LP position itself
     * will be.
     */
    function test_TheBareLockerIsUntouchedByAnyVerifier() public {
        vm.prank(victim);
        uint256 id = bare_locker.lock(address(lp), 1_000 ether, _now() + YEAR, victim);

        // the attacker, holding every forged instrument in the world, still has nothing here
        vm.prank(ATTACKER);
        vm.expectRevert(liquidity_locker.not_beneficiary.selector);
        bare_locker.withdraw(id);
        vm.prank(ATTACKER);
        vm.expectRevert(liquidity_locker.not_beneficiary.selector);
        bare_locker.assign(id, ATTACKER);
        vm.prank(ATTACKER);
        vm.expectRevert(liquidity_locker.not_beneficiary.selector);
        bare_locker.extend(id, _now() + 10 * YEAR);
    }

    /// A hostile verifier cannot open a lock whose gates have not passed. It forges WHO,
    /// never WHEN — the gates live in the locker's own storage and take no signature.
    function test_HostileVerifierStillCannotBeatTheGates() public {
        vm.prank(victim);
        uint256 id = hostile_door.lock_your_own(address(lp), 1_000 ether, _now() + YEAR);
        vm.prank(ATTACKER);
        vm.expectRevert(liquidity_locker.still_locked.selector);
        hostile_door.open_door(victim, id, ATTACKER, block.timestamp + 1 hours, bytes(hex""));
        emit log_string("the forged instruction still waited for the gate");
    }

    // ─────────────────────────── 4. it is checkable before you trust it
    /**
     * The mitigation is not code, it is procedure — but the procedure is possible only
     * because the verifier is PUBLIC and IMMUTABLE. Anyone can read which contract a
     * deployed door trusts, once, and the answer can never change afterwards.
     */
    function test_TheVerifierIsPublicAndImmutable() public view {
        assertEq(address(honest_door.VERIFIER()), address(good), "honest door names the wrong verifier");
        assertEq(address(hostile_door.VERIFIER()), address(evil), "hostile door hides its verifier");
        // and the scheme it claims is readable too
        assertEq(good.schemeId(), keccak256("ECDSA-secp256k1-v1"), "unexpected scheme id on the honest verifier");
        assertTrue(evil.schemeId() != good.schemeId(), "a hostile verifier could not be told apart by scheme");
    }
}
