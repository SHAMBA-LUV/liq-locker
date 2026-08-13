// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * ECDSA DIFFERENTIAL FUZZ — AUDIT §5, item 1.
 *
 *   "Differential fuzz of ECDSALib against OpenZeppelin's ECDSA. Inherited unwritten from
 *    bankon-vault, where it is also listed as the highest-value missing test."
 *
 * WHY THIS IS THE HIGHEST-VALUE MISSING TEST. `ECDSALib` is the primitive the whole door
 * rests on: `locker_door` accepts a signed instruction, and if recovery can be fooled the
 * lock can be opened by someone who was never authorised. It is 40 lines of hand-written
 * assembly, and hand-written recovery is where this class of bug lives — the EIP-2
 * malleability window, the `v` encoding, and the `ecrecover(...) == address(0)` case that
 * turns a malformed signature into "anyone".
 *
 * Rather than assert what the library should do, this compares it to the reference the rest
 * of the industry uses: OpenZeppelin's `ECDSA` v5.7.0, vendored verbatim into
 * `test/reference/OZ_ECDSA.sol` FOR TESTS ONLY. Nothing in `src/` imports it and it never
 * enters the deployed bytecode — the zero-dependency rule is about what ships, and nothing
 * here ships. It is vendored rather than submoduled for a second reason: OpenZeppelin's
 * repository carries its own foundry.toml pinning an evm_version this toolchain does not
 * recognise, and foundry reads nested configs when resolving remappings.
 *
 * THE CONTRACT BETWEEN THEM. They are not required to behave identically, and one deliberate
 * difference is asserted rather than smoothed over: OZ's `recover` reverts on a malleable
 * (high-s) signature, and so does ours; but where OZ's `tryRecover` returns an error code,
 * ours reverts with a named error. What MUST agree is the only thing that matters for
 * safety: **whenever either one yields an address, they yield the SAME address, and neither
 * ever yields a nonzero address for a signature the other rejects.**
 */

import "forge-std/Test.sol";
import {ECDSALib} from "../src/ecdsa_lib.sol";
import {ECDSA} from "./reference/OZ_ECDSA.sol";

/// thin wrappers so `try` can catch library reverts
contract ours {
    function recover(bytes32 h, bytes memory sig) external pure returns (address) {
        return ECDSALib.recover(h, sig);
    }
    function isValidSignatureNow(address s, bytes32 h, bytes memory sig) external view returns (bool) {
        return ECDSALib.isValidSignatureNow(s, h, sig);
    }
}

contract ecdsa_differential_test is Test {
    ours internal L;
    /// secp256k1n / 2 — the EIP-2 bound
    uint256 internal constant HALF_ORDER =
        0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;
    uint256 internal constant N =
        0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    function setUp() public { L = new ours(); }

    function _tryOurs(bytes32 h, bytes memory sig) internal view returns (bool ok, address who) {
        try L.recover(h, sig) returns (address a) { return (true, a); } catch { return (false, address(0)); }
    }
    function _tryOZ(bytes32 h, bytes memory sig) internal pure returns (bool ok, address who) {
        (address a, ECDSA.RecoverError e, ) = ECDSA.tryRecover(h, sig);
        return (e == ECDSA.RecoverError.NoError, a);
    }

    // ─────────────────────────── the core agreement, over real signatures
    /**
     * Any honestly-produced signature: both must recover, and to the same signer.
     */
    function testFuzz_HonestSignaturesAgree(uint256 pk, bytes32 digest) public view {
        pk = bound(pk, 1, N - 1);
        address expected = vm.addr(pk);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        (bool ok_ours, address a_ours) = _tryOurs(digest, sig);
        (bool ok_oz,   address a_oz)   = _tryOZ(digest, sig);

        assertTrue(ok_ours, "ours rejected an honest signature");
        assertTrue(ok_oz, "OZ rejected an honest signature");
        assertEq(a_ours, expected, "ours recovered the wrong signer");
        assertEq(a_ours, a_oz, "ours and OZ disagree on the signer");
    }

    /**
     * THE SAFETY PROPERTY, over arbitrary bytes. Neither implementation may return a
     * nonzero address that the other rejects, and where both accept they must agree.
     * This is the one that would catch a hand-rolled recovery accepting something the
     * reference refuses.
     */
    function testFuzz_NeverDisagreeOnArbitraryInput(bytes32 digest, bytes memory sig) public view {
        (bool ok_ours, address a_ours) = _tryOurs(digest, sig);
        (bool ok_oz,   address a_oz)   = _tryOZ(digest, sig);

        if (ok_ours && ok_oz) {
            assertEq(a_ours, a_oz, "both accepted, different signers");
        } else {
            assertFalse(ok_ours && !ok_oz, "ours accepted a signature OpenZeppelin rejects");
        }
        // ok_oz && !ok_ours is permitted: ours is deliberately the stricter of the two
        // (it also refuses signer == address(0) downstream), and stricter is safe.
        if (ok_ours) assertTrue(a_ours != address(0), "ours returned the zero address as a signer");
    }

    /// Structured fuzz: a real signature with the fields independently corrupted.
    function testFuzz_CorruptedFieldsAgree(uint256 pk, bytes32 digest, uint8 vRaw, bytes32 rX, bytes32 sX)
        public view
    {
        pk = bound(pk, 1, N - 1);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        // corrupt each field by XOR so the values stay in-range but wrong
        bytes memory sig = abi.encodePacked(r ^ rX, s ^ sX, uint8(vRaw));
        (bool ok_ours, address a_ours) = _tryOurs(digest, sig);
        (bool ok_oz,   address a_oz)   = _tryOZ(digest, sig);
        if (ok_ours && ok_oz) assertEq(a_ours, a_oz, "disagreement on a corrupted signature");
        if (ok_ours) assertTrue(a_ours != address(0), "zero signer accepted");
        // silence unused-var warnings while keeping the signature shape explicit
        v; s;
    }

    // ─────────────────────────── the specific hazards, pinned
    /// EIP-2: the high-s twin of a valid signature must be refused by both.
    function testFuzz_MalleableTwinRejectedByBoth(uint256 pk, bytes32 digest) public view {
        pk = bound(pk, 1, N - 1);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        // flip to the other valid (r, s) for the same message: s' = n - s, v' = 27^28
        bytes32 s_flipped = bytes32(N - uint256(s));
        uint8 v_flipped = v == 27 ? 28 : 27;
        if (uint256(s_flipped) <= HALF_ORDER) return;      // already canonical; nothing to test
        bytes memory malleable = abi.encodePacked(r, s_flipped, v_flipped);

        (bool ok_ours, ) = _tryOurs(digest, malleable);
        (bool ok_oz, )   = _tryOZ(digest, malleable);
        assertFalse(ok_ours, "ours accepted a malleable high-s signature");
        assertFalse(ok_oz, "OZ accepted a malleable high-s signature (reference changed?)");
    }

    /// v outside {27, 28} must be refused by both, for every other value.
    function testFuzz_BadVRejectedByBoth(uint256 pk, bytes32 digest, uint8 v) public view {
        vm.assume(v != 27 && v != 28);
        pk = bound(pk, 1, N - 1);
        (, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        bytes memory sig = abi.encodePacked(r, s, v);
        (bool ok_ours, ) = _tryOurs(digest, sig);
        (bool ok_oz, )   = _tryOZ(digest, sig);
        assertFalse(ok_ours, "ours accepted an out-of-range v");
        assertFalse(ok_oz, "OZ accepted an out-of-range v");
    }

    /// Any length but 65 must be refused by both.
    function testFuzz_WrongLengthRejectedByBoth(bytes32 digest, bytes memory sig) public view {
        vm.assume(sig.length != 65);
        (bool ok_ours, ) = _tryOurs(digest, sig);
        (bool ok_oz, )   = _tryOZ(digest, sig);
        assertFalse(ok_ours, "ours accepted a signature of the wrong length");
        assertFalse(ok_oz, "OZ accepted a signature of the wrong length");
    }

    /**
     * THE ZERO-SIGNER TRAP, stated as its own test because it is the one that turns a
     * recovery bug into "anyone may sign". `ecrecover` returns address(0) for malformed
     * input; if a verifier compares that to a stored signer that is ALSO address(0), any
     * signature authorises. `isValidSignatureNow` must refuse a zero signer outright.
     */
    function testFuzz_ZeroSignerNeverValidates(bytes32 digest, bytes memory sig) public view {
        assertFalse(L.isValidSignatureNow(address(0), digest, sig),
            "a zero signer validated - any signature would authorise");
    }

    /// And the honest path still works through the non-reverting entry point.
    function testFuzz_IsValidSignatureNowMatchesRecover(uint256 pk, bytes32 digest) public view {
        pk = bound(pk, 1, N - 1);
        address signer = vm.addr(pk);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        bytes memory sig = abi.encodePacked(r, s, v);
        assertTrue(L.isValidSignatureNow(signer, digest, sig), "valid signature rejected");
        assertFalse(L.isValidSignatureNow(address(uint160(signer) ^ 1), digest, sig),
            "signature validated for the wrong signer");
    }
}
