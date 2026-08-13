// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.0;

import "forge-std/Test.sol";
import {TimeBase} from "./time_base.sol";
import {liquidity_locker} from "../src/liquidity_locker.sol";
import {locker_door} from "../src/locker_door.sol";
import {VerifierECDSA} from "../src/verifier_ecdsa.sol";
import {ISignatureVerifier} from "../src/i_signature_verifier.sol";
import {ECDSALib} from "../src/ecdsa_lib.sol";
import {safe_token} from "../src/in_house.sol";
import {mock_erc20} from "./mocks.sol";

/**
 * Regressions for the 2026-08-10 review (F1, F2).
 *
 * Both findings were LATENT: the contract as assembled was safe, and unsafe only when
 * decomposed. That is the hardest class to keep fixed, because nothing visibly breaks
 * when the guard is removed again — the next refactor simply becomes exploitable in
 * silence. These tests exercise the primitives DIRECTLY, not through the paths that
 * currently happen to protect them, so a future edit that reintroduces either fault
 * fails here rather than on-chain.
 */
contract audit_regressions_test is TimeBase {
    VerifierECDSA internal verifier;
    locker_door internal D;
    mock_erc20 internal lp;

    address internal sink = address(0x5142);
    address internal overlord = address(0x0FE4);
    address internal overseer = address(0x0E5E);

    function setUp() public {
        _startClock(1_800_000_000);
        verifier = new VerifierECDSA();
        D = new locker_door(sink, overlord, overseer, ISignatureVerifier(address(verifier)));
        lp = new mock_erc20();
    }

    // ─────────────────────────────────────────────────────────────── F1 (high)
    /**
     * `ecrecover` returns address(0) for a malformed signature. If the claimed signer is
     * ALSO address(0), the equality that authorises the call is `0 == 0`, and every
     * signature in the universe validates. `recover()` always rejected this; the
     * non-reverting path wired to VerifierECDSA — the one the door actually trusts —
     * did not.
     */
    function test_ZeroSignerIsNeverValid() public view {
        bytes32 digest = keccak256("anything at all");

        // Garbage of the right length, and a low-s value so the malleability guard is
        // not what rejects it. This is the exact shape that used to authorise.
        bytes memory garbage = abi.encodePacked(bytes32(uint256(1)), bytes32(uint256(2)), uint8(27));
        assertFalse(verifier.verify(address(0), digest, garbage), "zero signer must never validate");

        // Empty and oversized signatures are refused for a zero signer too.
        assertFalse(verifier.verify(address(0), digest, ""), "empty sig, zero signer");
        assertFalse(verifier.verify(address(0), digest, new bytes(65)), "zero sig, zero signer");
    }

    /// @dev The strict path keeps its own guard; both must hold independently.
    ///      r = 0 is what actually forces `ecrecover` to return address(0): arbitrary
    ///      nonzero (r, s) is usually a MATHEMATICALLY VALID signature that recovers to
    ///      some real address, which is why "random bytes" is not a test of this at all.
    function test_StrictRecoverStillRejectsZeroSigner() public {
        bytes memory zeroR = abi.encodePacked(bytes32(0), bytes32(uint256(1)), uint8(27));
        vm.expectRevert(ECDSALib.ZeroSigner.selector);
        this.callRecover(keccak256("x"), zeroR);
    }

    /// @dev And the same input through the non-reverting path, for a NON-zero claimed
    ///      signer: it must return false rather than accidentally matching.
    function test_ZeroRecoveryDoesNotMatchARealSigner() public view {
        bytes memory zeroR = abi.encodePacked(bytes32(0), bytes32(uint256(1)), uint8(27));
        assertFalse(verifier.verify(address(0xA11CE), keccak256("x"), zeroR));
    }

    function callRecover(bytes32 h, bytes memory sig) external pure returns (address) {
        return ECDSALib.recover(h, sig);
    }

    /// @dev A real signer with a real signature still works — the guard must not be a
    ///      blanket refusal that quietly breaks the door.
    function test_RealSignerStillValidates() public view {
        uint256 pk = 0xA11CE;
        bytes32 digest = keccak256("consent");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        assertTrue(
            verifier.verify(vm.addr(pk), digest, abi.encodePacked(r, s, v)),
            "a genuine signature must still pass"
        );
    }

    /// @dev The door's own entry points refuse a zero beneficiary outright, so the
    ///      authorisation layer is not the only thing standing between a caller and a
    ///      lock. Belt and braces, deliberately.
    function test_DoorRefusesZeroBeneficiary() public {
        bytes memory sig = abi.encodePacked(bytes32(uint256(1)), bytes32(uint256(2)), uint8(27));
        vm.expectRevert(liquidity_locker.zero_address.selector);
        D.open_door(address(0), 0, address(0xBEEF), block.timestamp + 1 days, sig);

        vm.expectRevert(liquidity_locker.zero_address.selector);
        D.extend_by_sig(address(0), 0, uint48(block.timestamp + 30 days), block.timestamp + 1 days, sig);
    }

    // ─────────────────────────────────────────────────────────────── F2 (medium)
    /**
     * A `call` to an address with no code returns ok=true and empty return data, which
     * the success condition read as a completed transfer. Every path in the contract
     * happens to call `balanceOf` first — and Solidity inserts its own extcodesize check
     * for calls that decode a return value — so the gap was closed by call ORDER rather
     * than by the library. A library may not depend on how its callers are arranged.
     */
    function test_CodelessTokenIsRejected() public {
        address notAToken = address(0xDEAD00);
        assertEq(notAToken.code.length, 0, "precondition: the address has no code");

        vm.expectRevert(safe_token.transfer_failed.selector);
        this.callSafeTransfer(notAToken, address(0xBEEF), 1 ether);

        vm.expectRevert(safe_token.transfer_from_failed.selector);
        this.callSafeTransferFrom(notAToken, address(this), address(0xBEEF), 1 ether);
    }

    /// @dev An EOA is the case that shows up in practice: a mistyped token address.
    function test_EoaIsRejectedAsAToken() public {
        address eoa = vm.addr(0xBEEF);
        assertEq(eoa.code.length, 0);
        vm.expectRevert(safe_token.transfer_failed.selector);
        this.callSafeTransfer(eoa, address(0xCAFE), 1);
    }

    /// @dev A real token still transfers — the guard must not reject the good case.
    function test_RealTokenStillTransfers() public {
        lp.mint(address(this), 10 ether);
        this.callSafeTransfer(address(lp), address(0xBEEF), 4 ether);
        assertEq(lp.balanceOf(address(0xBEEF)), 4 ether);
    }

    // External wrappers so `vm.expectRevert` sees a call boundary rather than an
    // internal library jump.
    function callSafeTransfer(address token, address to, uint256 amount) external {
        safe_token.safe_transfer(token, to, amount);
    }

    function callSafeTransferFrom(address token, address from, address to, uint256 amount) external {
        safe_token.safe_transfer_from(token, from, to, amount);
    }
}
