// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.0;

import {liquidity_locker} from "../src/liquidity_locker.sol";

/// @notice Plain, well-behaved ERC-20. Returns true, takes no fee.
contract mock_erc20 {
    string public name = "Mock";
    string public symbol = "MOCK";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) public {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) public returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) public virtual returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public virtual returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @notice Burns `fee_bps` of every transfer. The reason every credit is a measured delta.
contract mock_fee_token is mock_erc20 {
    uint256 public fee_bps = 500; // 5%

    function transfer(address to, uint256 amount) public override returns (bool) {
        uint256 fee = (amount * fee_bps) / 10_000;
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount - fee;
        totalSupply -= fee;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        uint256 fee = (amount * fee_bps) / 10_000;
        balanceOf[from] -= amount;
        balanceOf[to] += amount - fee;
        totalSupply -= fee;
        return true;
    }
}

/// @notice USDT-style: mutates state correctly but returns NO data. A bare interface
///         call against this reverts in the ABI decoder, which is why safe_token exists.
contract mock_no_return_token {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) public {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) public {
        allowance[msg.sender][spender] = amount;
    }

    function transfer(address to, uint256 amount) public {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }

    function transferFrom(address from, address to, uint256 amount) public {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

/// @notice Returns false instead of reverting. safe_token must treat this as failure.
contract mock_false_token is mock_erc20 {
    function transfer(address, uint256) public pure override returns (bool) {
        return false;
    }
}

/// @notice Calls back into the locker on every transfer out. Models an ERC-777-style
///         hook or a malicious LP token trying to withdraw the same lock twice.
contract mock_reentrant_token is mock_erc20 {
    liquidity_locker public target;
    uint256 public attack_id;
    bool public armed;
    bool public reentered;
    bytes public last_error;

    function arm(liquidity_locker t, uint256 id) external {
        target = t;
        attack_id = id;
        armed = true;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (armed) {
            armed = false;
            reentered = true;
            try target.withdraw(attack_id) {
                revert("REENTRY_SUCCEEDED");
            } catch (bytes memory err) {
                last_error = err;
            }
        }
        return super.transfer(to, amount);
    }
}

/// @notice ERC-1271 contract signer. Accepts exactly one digest.
contract mock_erc1271 {
    bytes32 public expected;

    constructor(bytes32 expected_) {
        expected = expected_;
    }

    function isValidSignature(bytes32 digest, bytes calldata) external view returns (bytes4) {
        return digest == expected ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }
}

/// @notice Refuses ETH. Used to prove a payee that reverts on receive cannot brick the door.
contract mock_ether_refuser {
    receive() external payable {
        revert("NO_ETH");
    }
}
