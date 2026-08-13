// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.0;

import {ISignatureVerifier} from "./i_signature_verifier.sol";
import {ECDSALib} from "./ecdsa_lib.sol";

/**
 * @title  VerifierECDSA
 * @notice The launch verifier: secp256k1 ECDSA with ERC-1271 fallback.
 * @dev    Stateless, immutable, no constructor arguments. Deploy once, reference from
 *         VerifierRegistry.
 *
 *         This contract has a known expiry date. secp256k1 falls to Shor's algorithm;
 *         only the timing is open. When that happens, deploy a post-quantum verifier,
 *         propose it on the registry, and retire this scheme. The rest of the system
 *         does not change.
 */
contract VerifierECDSA is ISignatureVerifier {
    function verify(address signer, bytes32 digest, bytes calldata signature)
        external
        view
        override
        returns (bool)
    {
        return ECDSALib.isValidSignatureNow(signer, digest, signature);
    }

    function schemeId() external pure override returns (bytes32) {
        return keccak256("ECDSA-secp256k1-v1");
    }
}
