// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.0;

import "forge-std/Script.sol";
import {liquidity_locker} from "../src/liquidity_locker.sol";
import {locker_door} from "../src/locker_door.sol";
import {VerifierECDSA} from "../src/verifier_ecdsa.sol";
import {ISignatureVerifier} from "../src/i_signature_verifier.sol";

/**
 * @title  Deploy
 * @notice Deploys the free primitive, a launch verifier, and the optional door.
 *
 * @dev    EVERY ARGUMENT HERE IS IRREVERSIBLE. There are no setters in either contract,
 *         so a mistake in this script is fixed by deploying again, not by correcting it.
 *         Read `usage.md` §3 before running with --broadcast.
 *
 *         VERIFIER. Set VERIFIER_ADDR to bankon-vault's VerifierRegistry if you want the
 *         signature scheme to remain swappable behind its 180-day timelock — that is the
 *         whole reason the door takes an ISignatureVerifier instead of calling ECDSA
 *         directly. Leave it unset and this script deploys a bare VerifierECDSA, which
 *         is correct and simple and permanently secp256k1. Choose deliberately: a lock
 *         written for ten years should not hardcode a primitive with a known expiry.
 */
contract Deploy is Script {
    function run() external {
        address surplus_sink = vm.envAddress("SURPLUS_SINK");
        address overlord = vm.envAddress("OVERLORD");
        address overseer = vm.envAddress("OVERSEER");
        address verifier_addr = vm.envOr("VERIFIER_ADDR", address(0));

        vm.startBroadcast();

        // The free path. No fee, no signatures, no privileged address anywhere.
        liquidity_locker locker = new liquidity_locker(surplus_sink);
        console2.log("liquidity_locker :", address(locker));

        if (verifier_addr == address(0)) {
            verifier_addr = address(new VerifierECDSA());
            console2.log("VerifierECDSA    :", verifier_addr);
            console2.log("  NOTE: scheme is now fixed at secp256k1 for this door forever.");
        } else {
            console2.log("verifier (given) :", verifier_addr);
        }

        // The serviced path. Same locks, same storage layout, plus consent and relay.
        locker_door door =
            new locker_door(surplus_sink, overlord, overseer, ISignatureVerifier(verifier_addr));
        console2.log("locker_door      :", address(door));

        vm.stopBroadcast();

        console2.log("");
        console2.log("Locks created through the door live in the door's own storage.");
        console2.log("The two deployments do not share locks. This is intended.");
    }
}
