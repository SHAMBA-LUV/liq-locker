// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.0;

/**
 * @title  ISignatureVerifier
 * @notice The only place this system knows what a signature is.
 * @dev    Swapping the implementation behind VerifierRegistry migrates the entire
 *         system from ECDSA to ML-DSA (FIPS 204), SLH-DSA (FIPS 205), or whatever
 *         exists decades from now — without moving an asset or changing any other
 *         contract.
 *
 *         Implementations MUST be stateless and view-only. A verifier that writes
 *         storage is a verifier that can be griefed.
 */
interface ISignatureVerifier {
    /// @return valid true iff `signature` authorizes `digest` for `signer`.
    function verify(address signer, bytes32 digest, bytes calldata signature)
        external
        view
        returns (bool valid);

    /// @return id Opaque scheme identifier, e.g. keccak256("ECDSA-secp256k1-v1").
    function schemeId() external pure returns (bytes32 id);
}
