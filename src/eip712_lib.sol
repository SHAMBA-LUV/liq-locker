// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.0;

/**
 * @title  EIP712Lib
 * @notice Domain separator with fork protection.
 * @dev    The separator binds name, version, chainId, and verifyingContract, which
 *         defeats cross-chain and cross-contract signature replay for free. If chainid
 *         changes after deployment (a chain fork), the separator is rebuilt so
 *         signatures do not replay across the fork.
 */
abstract contract EIP712Lib {
    bytes32 private constant _DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );

    bytes32 private immutable _cachedSeparator;
    uint256 private immutable _cachedChainId;
    address private immutable _cachedThis;
    bytes32 private immutable _hashedName;
    bytes32 private immutable _hashedVersion;

    constructor(string memory name_, string memory version_) {
        _hashedName = keccak256(bytes(name_));
        _hashedVersion = keccak256(bytes(version_));
        _cachedChainId = block.chainid;
        _cachedThis = address(this);
        _cachedSeparator = _build();
    }

    function _build() private view returns (bytes32) {
        return keccak256(
            abi.encode(_DOMAIN_TYPEHASH, _hashedName, _hashedVersion, block.chainid, address(this))
        );
    }

    function _domainSeparator() internal view returns (bytes32) {
        if (address(this) == _cachedThis && block.chainid == _cachedChainId) {
            return _cachedSeparator;
        }
        return _build();
    }

    function _hashTypedData(bytes32 structHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(hex"1901", _domainSeparator(), structHash));
    }

    function domainSeparator() external view returns (bytes32) {
        return _domainSeparator();
    }
}
