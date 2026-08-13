// SPDX-License-Identifier: Apache-2.0
// (c) 2026 BANKON / cypherpunk2048 — Apache-2.0
//
// locker_door — the signed entrance to liquidity_locker. The lock is the timelock;
// the door is the signature. Somebody may lock tokens FOR you, but only with your
// signed consent; at maturity your signature opens the lock and any stranger may
// carry the transaction and pay its gas. The signature is the key, not the sender.
pragma solidity >=0.8.0;

import {liquidity_locker} from "./liquidity_locker.sol";
import {EIP712Lib} from "./eip712_lib.sol";
import {ISignatureVerifier} from "./i_signature_verifier.sol";

/**
 * @title  locker_door
 * @notice liquidity_locker plus EIP-712 consent, gasless relay, and the φ fee.
 *
 * @dev    LINEAGE. Derived from SHAMBA LUV's LUVLockerDoor, which established the
 *         three door verbs — close the door for someone with their consent, open the
 *         door by signed order at maturity, extend by signature — and the φ fee.
 *         Two things changed, and both are the point of this file.
 *
 *         ONE. THE SCHEME IS SWAPPABLE. LUVLockerDoor calls `ECDSA.recover` directly
 *         and takes `(v, r, s)`. That hardcodes secp256k1 into a contract whose whole
 *         proposition is a lock measured in years. On the day ECDSA falls, such a door
 *         still works perfectly and holds the liquidity hostage forever — the lock
 *         becomes a tomb. This door calls ISignatureVerifier instead, the crypto-agility
 *         seam that bankon-vault already defines, and takes `bytes`. Point it at a bare
 *         verifier_ecdsa today; point it at bankon-vault's VerifierRegistry and the
 *         scheme can migrate to ML-DSA (FIPS 204) or SLH-DSA (FIPS 205) behind a
 *         180-day timelock without moving a single locked token. Taking `bytes` rather
 *         than `(v, r, s)` is what makes that possible: a post-quantum signature does
 *         not fit in 65 bytes, and it is also what admits ERC-1271 contract signers —
 *         so a multisig treasury or an EIP-7702 delegated account can hold a lock. The
 *         BANKON owner is exactly such an account.
 *
 *         TWO. THE FEE RECIPIENTS ARE IMMUTABLE. LUVLockerDoor has `setOverseer`.
 *         A mutable payee is an admin key wearing a different hat, and this house does
 *         not keep those. Both shares are fixed at construction. If the stewardship
 *         changes, deploy another door — the locks live in the base contract's storage
 *         and are not affected by which door was used to create them.
 *
 *         WHAT THE DOOR CANNOT DO. It inherits liquidity_locker and adds no power over
 *         existing locks. It cannot shorten maturity, cannot reach principal, cannot
 *         pause. Exits are never charged and never gated: `withdraw` on the base
 *         contract remains free and open even if every door function is unusable.
 */
contract locker_door is liquidity_locker, EIP712Lib {
    // ------------------------------------------------------------------- errors
    error signature_expired();
    error bad_signer();
    error fee_short(uint256 required, uint256 sent);
    error nothing_owed();
    error eth_transfer_failed();
    error refund_failed();

    // ------------------------------------------------------------------- events
    event door_closed(uint256 indexed id, address indexed beneficiary, address indexed funder, uint256 fee);
    event door_opened(uint256 indexed id, address indexed beneficiary, address to, address relayer);
    event door_extended(uint256 indexed id, address indexed beneficiary, uint48 new_unlock_at);
    event bankon_fee(address indexed payer, uint256 fee, uint256 to_overlord, uint256 to_overseer);
    event fees_collected(address indexed to, uint256 amount);

    // ---------------------------------------------------------------- constants
    /// @dev φ to 18 decimals. Same value as BANKON's cp2048_constants.PHI_WAD and
    ///      LUVLockerDoor's PHI_WAD — one constant, three repositories, no drift.
    uint256 public constant PHI_WAD = 1_618033988749894848;

    /// @dev The gas anchor a lock is priced against.
    uint256 public constant LOCK_GAS_UNITS = 160_000;

    /// @dev BANKON hard-caps fees in the contract, never in config: cp2048_constants
    ///      sets MAX_FEE_NUM = 3, meaning a fee may never exceed three times the cost
    ///      of the call it prices. φ = 1.618… < 3, so the ceiling is satisfied by
    ///      construction rather than by a runtime check. `test_PhiFeeNeverExceedsCap`
    ///      asserts it over the whole gas-price range so a future edit to PHI_WAD
    ///      cannot quietly break it.
    uint256 public constant MAX_FEE_NUM = 3;

    /// @dev The DeltaVerse φ split: 61.8% / 38.2%, the golden section itself.
    uint256 public constant OVERLORD_BPS = 618;
    uint256 public constant SPLIT_SCALE = 1000;

    // --------------------------------------------------------------- immutables
    address public immutable OVERLORD;
    address public immutable OVERSEER;

    /// @notice The only place this contract knows what a signature is.
    ISignatureVerifier public immutable VERIFIER;

    // ---------------------------------------------------------------- typehashes
    bytes32 public constant LOCK_CONSENT_TYPEHASH = keccak256(
        "LockConsent(address token,uint256 amount,uint48 unlock_at,address funder,uint256 nonce,uint256 deadline)"
    );
    bytes32 public constant DOOR_OPEN_TYPEHASH =
        keccak256("DoorOpen(uint256 id,address to,uint256 nonce,uint256 deadline)");
    bytes32 public constant LOCK_EXTEND_TYPEHASH =
        keccak256("LockExtend(uint256 id,uint48 new_unlock_at,uint256 nonce,uint256 deadline)");

    // ------------------------------------------------------------------ storage
    /// @notice Per-signer replay protection. Shared across all three door verbs, so a
    ///         signature minted for one intent can never be replayed as another.
    mapping(address => uint256) public nonces;

    /// @notice Pull payment. Neither payee is ever pushed to during a lock, so a payee
    ///         that reverts on receive cannot brick the door for everyone else.
    mapping(address => uint256) public fees_owed;

    constructor(address surplus_sink_, address overlord_, address overseer_, ISignatureVerifier verifier_)
        liquidity_locker(surplus_sink_)
        EIP712Lib("locker_door", "1")
    {
        if (overlord_ == address(0) || overseer_ == address(0) || address(verifier_) == address(0)) {
            revert zero_address();
        }
        OVERLORD = overlord_;
        OVERSEER = overseer_;
        VERIFIER = verifier_;
    }

    // ------------------------------------------------------------------ the fee
    /**
     * @notice What a lock costs at gas price `gas_price_wei`: φ times its own gas bill.
     * @dev    The fee is denominated in the transaction's own gas price, so it tracks
     *         what the user is actually paying rather than a figure fixed years ago.
     *
     *         STATED PLAINLY: `tx.gasprice` is chosen by the caller, so the fee is
     *         adjustable downward by anyone willing to wait for their transaction to
     *         be mined at a low gas price. That is not a leak, it is the design — the
     *         fee is proportional to the cost of the service at the moment it is used,
     *         and a user who transacts cheaply is charged cheaply. Do not mistake this
     *         for a fee floor; there is none, and the door works at a gas price of zero.
     */
    function phi_fee(uint256 gas_price_wei) public pure returns (uint256) {
        return (LOCK_GAS_UNITS * gas_price_wei * PHI_WAD) / 1e18;
    }

    function _take_phi_fee() internal returns (uint256 fee) {
        fee = phi_fee(tx.gasprice);
        if (msg.value < fee) revert fee_short(fee, msg.value);

        uint256 to_overlord = (fee * OVERLORD_BPS) / SPLIT_SCALE;
        uint256 to_overseer = fee - to_overlord; // remainder, so no wei is stranded
        fees_owed[OVERLORD] += to_overlord;
        fees_owed[OVERSEER] += to_overseer;
        emit bankon_fee(msg.sender, fee, to_overlord, to_overseer);

        uint256 excess = msg.value - fee;
        if (excess != 0) {
            (bool ok,) = msg.sender.call{value: excess}("");
            if (!ok) revert refund_failed();
        }
    }

    /// @notice Collect your accrued φ share. Pull, never push.
    function collect_fees() external non_reentrant returns (uint256 owed) {
        owed = fees_owed[msg.sender];
        if (owed == 0) revert nothing_owed();
        fees_owed[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: owed}("");
        if (!ok) revert eth_transfer_failed();
        emit fees_collected(msg.sender, owed);
    }

    // --------------------------------------------------------- lock your own
    /**
     * @notice Lock your own tokens for yourself, through the door.
     * @dev    Quote with `phi_fee(tx.gasprice)` and send it as value; overpayment is
     *         refunded in the same transaction. The free path is still there: call
     *         `lock` on the base contract and pay nothing.
     */
    function lock_your_own(address token, uint256 amount, uint48 unlock_at)
        external
        payable
        non_reentrant
        returns (uint256 id)
    {
        uint256 fee = _take_phi_fee();
        id = _lock_from(msg.sender, token, amount, unlock_at, msg.sender);
        emit door_closed(id, msg.sender, msg.sender, fee);
    }

    // ------------------------------------------------- close the door for another
    /**
     * @notice Lock FOR a beneficiary, with their signed consent.
     * @dev    The funder pays the tokens and the fee; the beneficiary owns the lock and
     *         is the only address that can ever open it. Consent is required because a
     *         lock is not purely a gift: it names an address that must still be
     *         reachable years from now, and nobody should be assigned that duty silently.
     *
     *         The signed digest commits to the funder, so consent to be locked for by
     *         one party is not consent to be locked for by another.
     */
    function lock_with_consent(
        address token,
        uint256 amount,
        uint48 unlock_at,
        address beneficiary,
        uint256 deadline,
        bytes calldata signature
    ) external payable non_reentrant returns (uint256 id) {
        if (block.timestamp > deadline) revert signature_expired();
        if (beneficiary == address(0)) revert zero_address();

        _check(
            beneficiary,
            keccak256(
                abi.encode(
                    LOCK_CONSENT_TYPEHASH, token, amount, unlock_at, msg.sender, nonces[beneficiary]++, deadline
                )
            ),
            signature
        );

        uint256 fee = _take_phi_fee();
        id = _lock_from(msg.sender, token, amount, unlock_at, beneficiary);
        emit door_closed(id, beneficiary, msg.sender, fee);
    }

    // -------------------------------------------------------------- open the door
    /**
     * @notice Open a matured lock by the beneficiary's signed order. Any relayer may
     *         submit it and pay the gas; proceeds go where the signature says.
     * @dev    No fee, ever, and no gate. A beneficiary who has lost the ability to
     *         transact — no gas, a censored address, a dead relay — can still be paid
     *         by handing a signature to anyone. Charging for an exit would make the
     *         lock conditional on solvency at maturity, which defeats it.
     */
    function open_door(
        address beneficiary,
        uint256 id,
        address to,
        uint256 deadline,
        bytes calldata signature
    ) external non_reentrant {
        if (block.timestamp > deadline) revert signature_expired();
        if (to == address(0)) revert zero_address();
        // Defence in depth for the zero-signer case. `_withdraw` would reject it
        // anyway because `_lock_from` cannot produce a zero beneficiary — but that
        // is an invariant of a different contract, and authorisation should not be
        // load-bearing on somebody else's accident.
        if (beneficiary == address(0)) revert zero_address();

        _check(
            beneficiary,
            keccak256(abi.encode(DOOR_OPEN_TYPEHASH, id, to, nonces[beneficiary]++, deadline)),
            signature
        );

        _withdraw(id, beneficiary, to);
        emit door_opened(id, beneficiary, to, msg.sender);
    }

    /// @notice Extend a lock by signature. Extend-only, like every other path.
    function extend_by_sig(
        address beneficiary,
        uint256 id,
        uint48 new_unlock_at,
        uint256 deadline,
        bytes calldata signature
    ) external non_reentrant {
        if (block.timestamp > deadline) revert signature_expired();
        if (beneficiary == address(0)) revert zero_address();

        _check(
            beneficiary,
            keccak256(abi.encode(LOCK_EXTEND_TYPEHASH, id, new_unlock_at, nonces[beneficiary]++, deadline)),
            signature
        );

        _extend_for(beneficiary, id, new_unlock_at);
        emit door_extended(id, beneficiary, new_unlock_at);
    }

    // ------------------------------------------------------------------ digests
    // Client-side helpers. A wallet signs what these return; the door recomputes them
    // and never trusts a digest supplied from outside.

    function lock_consent_digest(
        address token,
        uint256 amount,
        uint48 unlock_at,
        address funder,
        uint256 nonce,
        uint256 deadline
    ) external view returns (bytes32) {
        return _hashTypedData(
            keccak256(abi.encode(LOCK_CONSENT_TYPEHASH, token, amount, unlock_at, funder, nonce, deadline))
        );
    }

    function door_open_digest(uint256 id, address to, uint256 nonce, uint256 deadline)
        external
        view
        returns (bytes32)
    {
        return _hashTypedData(keccak256(abi.encode(DOOR_OPEN_TYPEHASH, id, to, nonce, deadline)));
    }

    function lock_extend_digest(uint256 id, uint48 new_unlock_at, uint256 nonce, uint256 deadline)
        external
        view
        returns (bytes32)
    {
        return _hashTypedData(keccak256(abi.encode(LOCK_EXTEND_TYPEHASH, id, new_unlock_at, nonce, deadline)));
    }

    // ---------------------------------------------------------------- internals
    /// @dev The single place a signature is judged. Everything else builds a struct
    ///      hash and hands it here, so there is exactly one line to audit and exactly
    ///      one line to change when the scheme does.
    function _check(address signer, bytes32 struct_hash, bytes calldata signature) internal view {
        if (!VERIFIER.verify(signer, _hashTypedData(struct_hash), signature)) revert bad_signer();
    }
}
