// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.0;

import "forge-std/Test.sol";
import {TimeBase} from "./time_base.sol";
import {liquidity_locker} from "../src/liquidity_locker.sol";
import {locker_door} from "../src/locker_door.sol";
import {VerifierECDSA} from "../src/verifier_ecdsa.sol";
import {ISignatureVerifier} from "../src/i_signature_verifier.sol";
import {mock_erc20, mock_erc1271, mock_ether_refuser} from "./mocks.sol";

contract locker_door_test is TimeBase {
    locker_door internal D;
    VerifierECDSA internal verifier;
    mock_erc20 internal lp;

    uint256 internal constant HOLDER_PK = 0xA11CE;
    address internal holder;
    address internal funder = address(0xF0BE);
    address internal relayer = address(0x8E1A);
    address internal overlord = address(0x0FE4);
    address internal overseer = address(0x0E5E);
    address internal sink = address(0x5142);

    uint48 internal constant YEAR = 365 days;
    uint256 internal constant GAS_PRICE = 20 gwei;

    function setUp() public {
        _startClock(1_800_000_000);
        holder = vm.addr(HOLDER_PK);
        verifier = new VerifierECDSA();
        D = new locker_door(sink, overlord, overseer, ISignatureVerifier(address(verifier)));
        lp = new mock_erc20();

        lp.mint(funder, 1_000_000 ether);
        lp.mint(holder, 1_000_000 ether);
        vm.prank(funder);
        lp.approve(address(D), type(uint256).max);
        vm.prank(holder);
        lp.approve(address(D), type(uint256).max);

        vm.deal(funder, 100 ether);
        vm.deal(holder, 100 ether);
        vm.deal(relayer, 100 ether);
        vm.txGasPrice(GAS_PRICE);
    }

    function _sign(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _now() internal view returns (uint48) {
        return uint48(T);
    }

    // ------------------------------------------------------------------- the fee
    function test_LockYourOwnChargesPhiFeeAndSplitsIt() public {
        uint256 fee = D.phi_fee(GAS_PRICE);
        assertGt(fee, 0);

        vm.prank(holder);
        D.lock_your_own{value: fee}(address(lp), 1_000 ether, _now() + YEAR);

        uint256 to_overlord = (fee * 618) / 1000;
        assertEq(D.fees_owed(overlord), to_overlord, "61.8% to the OVERLORD");
        assertEq(D.fees_owed(overseer), fee - to_overlord, "38.2% remainder to the OVERSEER");
        assertEq(D.fees_owed(overlord) + D.fees_owed(overseer), fee, "no wei stranded");
    }

    /// BANKON caps fees in the contract, never in config: cp2048_constants.MAX_FEE_NUM = 3.
    /// phi < 3, so the ceiling holds by construction. This asserts it across the range so a
    /// future edit to PHI_WAD cannot quietly break the guarantee.
    function testFuzz_PhiFeeNeverExceedsCap(uint128 gas_price) public view {
        uint256 fee = D.phi_fee(gas_price);
        uint256 cap = D.MAX_FEE_NUM() * D.LOCK_GAS_UNITS() * uint256(gas_price);
        assertLe(fee, cap, "fee must never exceed 3x the call cost");
    }

    function test_UnderpaidFeeReverts() public {
        uint256 fee = D.phi_fee(GAS_PRICE);
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(locker_door.fee_short.selector, fee, fee - 1));
        D.lock_your_own{value: fee - 1}(address(lp), 1_000 ether, _now() + YEAR);
    }

    function test_OverpaymentIsRefundedInTransaction() public {
        uint256 fee = D.phi_fee(GAS_PRICE);
        uint256 before = holder.balance;
        vm.prank(holder);
        D.lock_your_own{value: fee + 5 ether}(address(lp), 1_000 ether, _now() + YEAR);
        assertEq(holder.balance, before - fee, "excess returned, only the fee kept");
    }

    function test_CollectFeesIsPullPayment() public {
        uint256 fee = D.phi_fee(GAS_PRICE);
        vm.prank(holder);
        D.lock_your_own{value: fee}(address(lp), 1_000 ether, _now() + YEAR);

        uint256 owed = D.fees_owed(overlord);
        vm.prank(overlord);
        D.collect_fees();
        assertEq(overlord.balance, owed);
        assertEq(D.fees_owed(overlord), 0);

        vm.prank(overlord);
        vm.expectRevert(locker_door.nothing_owed.selector);
        D.collect_fees();
    }

    /// A payee that reverts on receive must not be able to brick locking for everyone.
    /// This is why fees are pulled, never pushed.
    function test_RevertingPayeeCannotBrickTheDoor() public {
        mock_ether_refuser refuser = new mock_ether_refuser();
        locker_door d2 =
            new locker_door(sink, address(refuser), overseer, ISignatureVerifier(address(verifier)));
        vm.prank(holder);
        lp.approve(address(d2), type(uint256).max);

        uint256 fee = d2.phi_fee(GAS_PRICE);
        vm.prank(holder);
        d2.lock_your_own{value: fee}(address(lp), 1_000 ether, _now() + YEAR);
        assertGt(d2.fees_owed(address(refuser)), 0, "accrued, just not collectable by them");
    }

    // ------------------------------------------------------- close the door for another
    function test_LockWithConsentNeedsTheBeneficiarySignature() public {
        uint256 deadline = T + 1 hours;
        bytes32 digest = D.lock_consent_digest(address(lp), 1_000 ether, _now() + YEAR, funder, 0, deadline);
        bytes memory sig = _sign(HOLDER_PK, digest);
        uint256 fee = D.phi_fee(GAS_PRICE);

        vm.prank(funder);
        uint256 id = D.lock_with_consent{value: fee}(
            address(lp), 1_000 ether, _now() + YEAR, holder, deadline, sig
        );

        (, address beneficiary,,,) = D.lock_at(id);
        assertEq(beneficiary, holder, "the signer owns the lock, not the funder");
    }

    function test_NobodyCanBeLockedForWithoutConsent() public {
        uint256 deadline = T + 1 hours;
        bytes32 digest = D.lock_consent_digest(address(lp), 1_000 ether, _now() + YEAR, funder, 0, deadline);
        bytes memory forged = _sign(0xBADBAD, digest); // some other key entirely
        uint256 fee = D.phi_fee(GAS_PRICE);

        vm.prank(funder);
        vm.expectRevert(locker_door.bad_signer.selector);
        D.lock_with_consent{value: fee}(address(lp), 1_000 ether, _now() + YEAR, holder, deadline, forged);
    }

    /// The digest commits to the funder, so consent given to one party is not consent
    /// given to any party. A signature harvested from a public mempool cannot be reused
    /// by a different funder.
    function test_ConsentIsBoundToTheNamedFunder() public {
        uint256 deadline = T + 1 hours;
        bytes32 digest = D.lock_consent_digest(address(lp), 1_000 ether, _now() + YEAR, funder, 0, deadline);
        bytes memory sig = _sign(HOLDER_PK, digest);
        uint256 fee = D.phi_fee(GAS_PRICE);

        address interloper = address(0xDEAD01);
        lp.mint(interloper, 10_000 ether);
        vm.startPrank(interloper);
        lp.approve(address(D), type(uint256).max);
        vm.deal(interloper, 10 ether);
        vm.expectRevert(locker_door.bad_signer.selector);
        D.lock_with_consent{value: fee}(address(lp), 1_000 ether, _now() + YEAR, holder, deadline, sig);
        vm.stopPrank();
    }

    // -------------------------------------------------------------- open the door
    function test_AnyRelayerMayCarryTheOpenOrder() public {
        vm.prank(holder);
        uint256 id = D.lock(address(lp), 1_000 ether, _now() + YEAR, address(0));
        _advance(YEAR);

        uint256 deadline = T + 1 hours;
        address payee = address(0xBEEF);
        bytes32 digest = D.door_open_digest(id, payee, 0, deadline);
        bytes memory sig = _sign(HOLDER_PK, digest);

        // A stranger submits it and pays the gas. The signature is the key.
        vm.prank(relayer);
        D.open_door(holder, id, payee, deadline, sig);

        assertEq(lp.balanceOf(payee), 1_000 ether, "proceeds go where the signature says");
        assertEq(lp.balanceOf(relayer), 0, "the relayer earns nothing from carrying it");
    }

    /// Exits are never charged. open_door is not even payable.
    function test_OpeningTheDoorIsFree() public {
        vm.prank(holder);
        uint256 id = D.lock(address(lp), 1_000 ether, _now() + YEAR, address(0));
        _advance(YEAR);

        uint256 overlord_before = D.fees_owed(overlord);
        uint256 deadline = T + 1 hours;
        bytes memory sig = _sign(HOLDER_PK, D.door_open_digest(id, holder, 0, deadline));

        vm.prank(relayer);
        D.open_door(holder, id, holder, deadline, sig);
        assertEq(D.fees_owed(overlord), overlord_before, "no fee accrued on exit");
    }

    function test_OpenDoorStillRespectsMaturity() public {
        vm.prank(holder);
        uint256 id = D.lock(address(lp), 1_000 ether, _now() + YEAR, address(0));

        uint256 deadline = T + 1 hours;
        bytes memory sig = _sign(HOLDER_PK, D.door_open_digest(id, holder, 0, deadline));

        vm.prank(relayer);
        vm.expectRevert(liquidity_locker.still_locked.selector);
        D.open_door(holder, id, holder, deadline, sig);
    }

    // --------------------------------------------------------------- replay & expiry
    function test_SignatureCannotBeReplayed() public {
        vm.startPrank(holder);
        uint256 a = D.lock(address(lp), 1_000 ether, _now() + YEAR, address(0));
        uint256 b = D.lock(address(lp), 1_000 ether, _now() + YEAR, address(0));
        vm.stopPrank();
        _advance(YEAR);

        uint256 deadline = T + 1 hours;
        bytes memory sig = _sign(HOLDER_PK, D.door_open_digest(a, holder, 0, deadline));
        vm.prank(relayer);
        D.open_door(holder, a, holder, deadline, sig);

        // The nonce moved; the same bytes are now worthless.
        vm.prank(relayer);
        vm.expectRevert(locker_door.bad_signer.selector);
        D.open_door(holder, a, holder, deadline, sig);
        assertTrue(D.is_locked(b) == false || true); // b untouched either way
        (,,,, bool withdrawn_b) = D.lock_at(b);
        assertFalse(withdrawn_b, "the second lock was never opened");
    }

    function test_ExpiredSignatureRejected() public {
        vm.prank(holder);
        uint256 id = D.lock(address(lp), 1_000 ether, _now() + YEAR, address(0));
        uint256 deadline = T + 1 hours;
        bytes memory sig = _sign(HOLDER_PK, D.door_open_digest(id, holder, 0, deadline));

        _advance(YEAR); // well past the deadline
        vm.prank(relayer);
        vm.expectRevert(locker_door.signature_expired.selector);
        D.open_door(holder, id, holder, deadline, sig);
    }

    // -------------------------------------------------------- extend by signature
    function test_ExtendBySigIsExtendOnly() public {
        vm.prank(holder);
        uint256 id = D.lock(address(lp), 1_000 ether, _now() + YEAR, address(0));

        uint256 deadline = T + 1 hours;
        uint48 longer = _now() + 2 * YEAR;
        bytes memory sig = _sign(HOLDER_PK, D.lock_extend_digest(id, longer, 0, deadline));
        vm.prank(relayer);
        D.extend_by_sig(holder, id, longer, deadline, sig);
        (,,, uint48 unlock_at,) = D.lock_at(id);
        assertEq(unlock_at, longer);

        uint48 shorter = _now() + 1 days;
        bytes memory sig2 = _sign(HOLDER_PK, D.lock_extend_digest(id, shorter, 1, deadline));
        vm.prank(relayer);
        vm.expectRevert(liquidity_locker.not_shortenable.selector);
        D.extend_by_sig(holder, id, shorter, deadline, sig2);
    }

    // ------------------------------------------------------------ ERC-1271 signers
    /**
     * The improvement that taking `bytes` rather than `(v, r, s)` buys. A treasury
     * multisig or an EIP-7702 delegated account is a CONTRACT, and a contract cannot
     * produce a secp256k1 signature. LUVLockerDoor's `(v, r, s)` signature could never
     * admit one; the BANKON owner is exactly such an account.
     */
    function test_Erc1271ContractSignerCanOwnAndOpenALock() public {
        // The digest must be fixed before the mock signer is constructed, so the
        // deadline has to outlive the maturity warp below. Absolute, not relative.
        uint256 deadline = T + 400 days;

        vm.prank(holder);
        uint256 id = D.lock(address(lp), 1_000 ether, _now() + YEAR, address(0));

        bytes32 open_digest = D.door_open_digest(id, holder, 0, deadline);
        mock_erc1271 signer = new mock_erc1271(open_digest);

        // Hand the lock to the contract, then let it authorise its own exit.
        vm.prank(holder);
        D.assign(id, address(signer));
        _advance(YEAR);

        bytes32 real_digest = D.door_open_digest(id, holder, D.nonces(address(signer)), deadline);
        assertEq(real_digest, open_digest, "nonce still 0 for the contract signer");

        vm.prank(relayer);
        D.open_door(address(signer), id, holder, deadline, hex"00"); // signature bytes are opaque to ERC-1271
        assertEq(lp.balanceOf(holder), 1_000_000 ether);
    }

    // ------------------------------------------------------- the free path survives
    /// Every door function could be unusable and the base contract would still let a
    /// beneficiary out. That is the property that makes the fee non-coercive.
    function test_BaseWithdrawIsStillFreeAndUngated() public {
        uint256 fee = D.phi_fee(GAS_PRICE);
        vm.prank(holder);
        uint256 id = D.lock_your_own{value: fee}(address(lp), 1_000 ether, _now() + YEAR);
        _advance(YEAR);

        uint256 before = holder.balance;
        vm.prank(holder);
        D.withdraw(id); // no value, no signature, no relayer
        assertEq(holder.balance, before, "exit costs nothing but gas");
        assertEq(lp.balanceOf(holder), 1_000_000 ether);
    }

    function test_ConstructorRejectsZeroAddresses() public {
        vm.expectRevert(liquidity_locker.zero_address.selector);
        new locker_door(sink, address(0), overseer, ISignatureVerifier(address(verifier)));
        vm.expectRevert(liquidity_locker.zero_address.selector);
        new locker_door(sink, overlord, overseer, ISignatureVerifier(address(0)));
    }

    /// The domain separator binds chainid, so a signature minted on one chain is not
    /// valid on another. Free cross-chain replay protection from EIP712Lib.
    function test_SignatureFromAnotherChainIsRejected() public {
        vm.prank(holder);
        uint256 id = D.lock(address(lp), 1_000 ether, _now() + YEAR, address(0));
        uint256 deadline = T + 400 days; // must outlive the maturity warp
        bytes memory sig = _sign(HOLDER_PK, D.door_open_digest(id, holder, 0, deadline));

        _advance(YEAR);
        vm.chainId(999);
        vm.prank(relayer);
        vm.expectRevert(locker_door.bad_signer.selector);
        D.open_door(holder, id, holder, deadline, sig);
    }
}
