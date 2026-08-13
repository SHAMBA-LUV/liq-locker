// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.0;

/**
 * @title  ECDSALib
 * @notice Recovery enforcing EIP-2 low-s, canonical v, and non-zero signer, plus an
 *         ERC-1271 branch for contract signers.
 * @dev    Raw ecrecover accepts malleable high-s signatures and returns address(0)
 *         on failure instead of reverting. Both are handled here.
 *
 *         Authored in-house. Before mainnet, differentially fuzz against a reference
 *         implementation over random (hash, v, r, s) — they must agree on every input.
 */
library ECDSALib {
    error BadSignatureLength(uint256 len);
    error MalleableSignature();
    error InvalidV(uint8 v);
    error ZeroSigner();

    bytes4 internal constant ERC1271_MAGIC = 0x1626ba7e;

    /// @dev secp256k1n / 2 — the EIP-2 upper bound on s (Yellow Paper Appendix F).
    uint256 internal constant HALF_ORDER =
        0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;

    /// @notice Strict recovery. Reverts on any irregularity.
    function recover(bytes32 hash, bytes memory sig) internal pure returns (address signer) {
        if (sig.length != 65) revert BadSignatureLength(sig.length);
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly ("memory-safe") {
            r := mload(add(sig, 0x20))
            s := mload(add(sig, 0x40))
            v := byte(0, mload(add(sig, 0x60)))
        }
        if (uint256(s) > HALF_ORDER) revert MalleableSignature();
        if (v != 27 && v != 28) revert InvalidV(v);
        signer = ecrecover(hash, v, r, s);
        if (signer == address(0)) revert ZeroSigner();
    }

    /// @notice Non-reverting check covering EOA and ERC-1271 contract signers.
    function isValidSignatureNow(address signer, bytes32 hash, bytes memory sig)
        internal
        view
        returns (bool)
    {
        // ecrecover returns address(0) on malformed input, so a zero `signer`
        // would compare equal to a failed recovery and authorise ANY signature.
        // `recover` above already refuses this; the non-reverting path must too,
        // because it is the one wired to VerifierECDSA and therefore the one the
        // door actually trusts. An auth primitive must not depend on its caller
        // to keep it safe — the whole point of ISignatureVerifier is that the
        // caller can be swapped.
        if (signer == address(0)) return false;
        if (signer.code.length == 0) {
            if (sig.length != 65) return false;
            bytes32 r;
            bytes32 s;
            uint8 v;
            assembly ("memory-safe") {
                r := mload(add(sig, 0x20))
                s := mload(add(sig, 0x40))
                v := byte(0, mload(add(sig, 0x60)))
            }
            if (uint256(s) > HALF_ORDER) return false;
            if (v != 27 && v != 28) return false;
            return ecrecover(hash, v, r, s) == signer;
        }
        (bool ok, bytes memory ret) =
            signer.staticcall(abi.encodeWithSelector(ERC1271_MAGIC, hash, sig));
        return ok && ret.length >= 32 && abi.decode(ret, (bytes4)) == ERC1271_MAGIC;
    }
}
