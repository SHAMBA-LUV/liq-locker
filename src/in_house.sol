// SPDX-License-Identifier: Apache-2.0
// (c) 2026 BANKON / cypherpunk2048 — Apache-2.0
//
// Zero-dependency primitives. This module imports nothing from npm, nothing from
// a package registry, nothing that a future maintainer must resolve from a network
// that may not exist. A lock intended to hold liquidity for a decade cannot inherit
// a supply chain. Derived from SHAMBA LUV's base/InHouse.sol, which made the same
// call for the same reason.
pragma solidity >=0.8.0;

/// @notice The subset of ERC-20 a locker actually needs. Deliberately not IERC20:
///         `transfer`/`transferFrom` are declared to return bool here, and the
///         non-compliant tokens that return nothing are handled by safe_token below.
interface i_erc20_min {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/**
 * @title  safe_token
 * @notice ERC-20 calls that tolerate the tokens people actually deploy.
 * @dev    USDT and its many descendants return nothing from transfer/transferFrom.
 *         A bare interface call reverts on those because the ABI decoder demands a
 *         32-byte return. This treats "no return data" as success and "returned
 *         false" as failure, which is the only reading consistent with both the
 *         standard and reality.
 */
library safe_token {
    error transfer_failed();
    error transfer_from_failed();

    /// @dev A `call` to an address with NO CODE succeeds and returns nothing, which
    ///      the return-data check below reads as success. Every current caller happens
    ///      to invoke `balanceOf` first — and Solidity inserts its own extcodesize
    ///      check for calls that decode a return value — so the gap is closed today by
    ///      the call order rather than by this library. That is not a property a
    ///      library may rely on: the next caller that transfers without reading a
    ///      balance first would silently treat a non-token as a successful transfer.
    function safe_transfer(address token, address to, uint256 amount) internal {
        if (token.code.length == 0) revert transfer_failed();
        (bool ok, bytes memory ret) =
            token.call(abi.encodeWithSelector(i_erc20_min.transfer.selector, to, amount));
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert transfer_failed();
    }

    function safe_transfer_from(address token, address from, address to, uint256 amount) internal {
        if (token.code.length == 0) revert transfer_from_failed();
        (bool ok, bytes memory ret) = token.call(
            abi.encodeWithSelector(i_erc20_min.transferFrom.selector, from, to, amount)
        );
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert transfer_from_failed();
    }
}

/**
 * @title  guarded
 * @notice Classic 1/2 mutex, plus a read-only reentrancy guard for views.
 * @dev    Not TSTORE/TLOAD. `evm_version = "paris"`, matching bankon-vault's stated
 *         reasoning: for a contract meant to outlive several EVM upgrades, take the
 *         ~5,000 gas and keep the certainty. This is a deliberate reversal of the
 *         usual gas-optimisation advice.
 *
 *         `when_not_entered` exists because an integrator reading a view mid-callback
 *         would otherwise be handed state caught between effects. Carried forward
 *         from the LUVLocker audit, which verified it as a property worth keeping.
 */
abstract contract guarded {
    error reentrant();

    uint256 private _lock = 1;

    modifier non_reentrant() {
        if (_lock != 1) revert reentrant();
        _lock = 2;
        _;
        _lock = 1;
    }

    modifier when_not_entered() {
        if (_lock != 1) revert reentrant();
        _;
    }
}
