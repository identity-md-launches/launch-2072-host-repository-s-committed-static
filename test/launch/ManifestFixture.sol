// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {DrandBeacon} from "src/DrandBeacon.sol";
import {IdentityMachine} from "src/IdentityMachine.sol";
import {MachineViews} from "src/MachineViews.sol";
import {EthMinter, EthPoolKey} from "src/EthMinter.sol";
import {Parts} from "src/Parts.sol";
import {LaunchFactoryProbe} from "../LaunchDeployment.t.sol";
import {CheckoutToken, SettlementPool, SettlementQuoter} from "./SettlementModel.sol";

/// The application bytecode and every constructor argument come from the committed launch.
/// Only the external IMD/Uniswap dependencies are modeled; application storage is never patched.
abstract contract ManifestFixture is Test {
    // Developer payout already recorded by the accepted launch rehearsal.
    address internal constant LAUNCH_DEV = address(bytes20(hex"7bfb800906d744b8f43286ca97ef7b32e61edb39"));
    uint256 internal constant POOL_TOKENS = 1e30;
    uint256 internal constant ACTOR_TOKENS = 1e26;
    uint256 internal constant ACTOR_ETH = 1e6 ether;

    DrandBeacon internal beacon;
    IdentityMachine internal machine;
    MachineViews internal views;
    EthMinter internal checkout;
    Parts internal inventory;
    CheckoutToken internal token;
    SettlementPool internal pool;
    address internal seatHolder;
    uint16 internal seat;
    bytes32[] internal seatProof;

    function _deployManifest(uint256 timestamp) internal {
        vm.chainId(4663);
        vm.warp(timestamp);
        string memory manifest = vm.readFile("launch.json");
        assertEq(vm.parseJsonString(manifest, ".kind"), "evm_contracts");
        string[] memory ma = vm.parseJsonStringArray(manifest, ".contracts[1].constructorArgs");
        string[] memory va = vm.parseJsonStringArray(manifest, ".contracts[2].constructorArgs");
        string[] memory ea = vm.parseJsonStringArray(manifest, ".contracts[3].constructorArgs");
        assertEq(vm.parseJsonStringArray(manifest, ".contracts[0].constructorArgs").length, 0);
        assertEq(ma.length, 6);
        assertEq(va.length, 1);
        assertEq(ea.length, 5);
        assertEq(ma[1], "$contract:DrandBeacon");
        assertEq(ma[2], "$owner");
        assertEq(va[0], "$contract:IdentityMachine");
        assertEq(ea[0], "$contract:IdentityMachine");

        LaunchFactoryProbe factory = new LaunchFactoryProbe();
        bytes[] memory code = new bytes[](4);
        bytes32[] memory salts = new bytes32[](4);
        address[] memory predicted = new address[](4);
        string[4] memory names = ["DrandBeacon", "IdentityMachine", "MachineViews", "EthMinter"];
        for (uint256 i; i < names.length; ++i) {
            assertEq(vm.parseJsonString(manifest, string.concat(".contracts[", vm.toString(i), "].contract")), names[i]);
            bytes memory args;
            if (i == 1) {
                args = abi.encode(
                    vm.parseAddress(ma[0]),
                    predicted[0],
                    LAUNCH_DEV,
                    vm.parseBytes32(ma[3]),
                    vm.parseUint(ma[4]),
                    vm.parseUint(ma[5])
                );
            } else if (i == 2) {
                args = abi.encode(predicted[1]);
            } else if (i == 3) {
                args = abi.encode(
                    predicted[1],
                    vm.parseAddress(ea[1]),
                    vm.parseAddress(ea[2]),
                    vm.parseUint(ea[3]),
                    vm.parseUint(ea[4])
                );
            }
            code[i] = bytes.concat(vm.getCode(string.concat(names[i], ".sol:", names[i])), args);
            salts[i] = keccak256(bytes(names[i]));
            predicted[i] = vm.computeCreate2Address(salts[i], keccak256(code[i]), address(factory));
        }
        // Forge 1.8: keep the full launch inside a single top-level transaction.
        address[] memory deployed = factory.deployAll(code, salts);
        assertEq(deployed, predicted);
        beacon = DrandBeacon(deployed[0]);
        machine = IdentityMachine(deployed[1]);
        views = MachineViews(deployed[2]);
        checkout = EthMinter(deployed[3]);
        inventory = Parts(address(machine.inventory()));

        // External dependencies deliberately appear only after the constructor rehearsal.
        address imd = address(machine.imd());
        address manager = address(checkout.poolManager());
        address quoter = address(checkout.quoter());
        assertEq(imd.code.length, 0);
        assertEq(manager.code.length, 0);
        assertEq(quoter.code.length, 0);
        CheckoutToken tokenImplementation = new CheckoutToken();
        vm.etch(imd, address(tokenImplementation).code);
        token = CheckoutToken(imd);
        EthPoolKey memory key = checkout.poolKey();
        SettlementPool poolImplementation = new SettlementPool(token, key.fee, key.tickSpacing);
        vm.etch(manager, address(poolImplementation).code);
        pool = SettlementPool(manager);
        SettlementQuoter quoterImplementation = new SettlementQuoter(pool);
        vm.etch(quoter, address(quoterImplementation).code);
        pool.setRate(0.0035 ether);
        token.mint(manager, POOL_TOKENS);

        string memory fixture = vm.readFile("test/fixtures-seat.json");
        assertEq(vm.parseJsonBytes32(fixture, ".root"), machine.seatRoot());
        seatHolder = vm.parseJsonAddress(fixture, ".owner");
        seat = uint16(vm.parseJsonUint(fixture, ".seat"));
        seatProof = vm.parseJsonBytes32Array(fixture, ".proof");
    }

    function _fundActor(address actor) internal {
        token.mint(actor, ACTOR_TOKENS);
        vm.deal(actor, ACTOR_ETH);
        vm.prank(actor);
        token.approve(address(machine), type(uint256).max);
    }

    function _claimCore() internal returns (uint256 id) {
        vm.prank(seatHolder);
        id = machine.claimAgentCore(seat, seatProof);
    }

    function _placeCore(uint256 id) internal {
        IdentityMachine.Spot[] memory spots = new IdentityMachine.Spot[](1);
        spots[0] = IdentityMachine.Spot(id, 0, 2, 0);
        uint256 r = machine.round();
        vm.prank(seatHolder);
        machine.build(r, new IdentityMachine.Proof[](0), new uint256[](0), spots, IdentityMachine.GrowthExit(2, 0, 2));
    }
}
