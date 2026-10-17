// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IdentityMachine} from "../src/IdentityMachine.sol";
import {MachineViews} from "../src/MachineViews.sol";
import {EthMinter} from "../src/EthMinter.sol";
import {Parts} from "../src/Parts.sol";

/// Rehearse the factory's zero-value CREATE2 batch in one transaction.
contract LaunchFactoryProbe {
    function deployAll(bytes[] memory codes, bytes32[] memory salts) external returns (address[] memory deployed) {
        deployed = new address[](codes.length);
        for (uint256 i; i < codes.length; ++i) {
            bytes memory code = codes[i];
            bytes32 salt = salts[i];
            require(code.length != 0 && code.length <= 49_152, "invalid init code");
            address created;
            assembly ("memory-safe") {
                created := create2(0, add(code, 32), mload(code), salt)
                if iszero(created) {
                    returndatacopy(0, 0, returndatasize())
                    revert(0, returndatasize())
                }
            }
            deployed[i] = created;
        }
    }
}

contract LaunchDeploymentTest is Test {
    address constant OWNER = address(bytes20(hex"7bfb800906d744b8f43286ca97ef7b32e61edb39"));

    function test_manifestDeploysInOneFactoryCallOnEmptyChain() public {
        vm.chainId(4663);
        vm.warp(1_800_000_000);
        string memory manifest = vm.readFile("launch.json");
        string[] memory machineArgs = vm.parseJsonStringArray(manifest, ".contracts[1].constructorArgs");
        string[] memory viewArgs = vm.parseJsonStringArray(manifest, ".contracts[2].constructorArgs");
        string[] memory minterArgs = vm.parseJsonStringArray(manifest, ".contracts[3].constructorArgs");
        assertEq(machineArgs[1], "$contract:DrandBeacon");
        assertEq(machineArgs[2], "$owner");
        assertEq(viewArgs[0], "$contract:IdentityMachine");
        assertEq(minterArgs[0], "$contract:IdentityMachine");
        address token = vm.parseAddress(machineArgs[0]);
        address manager = vm.parseAddress(minterArgs[1]);
        address quoter = vm.parseAddress(minterArgs[2]);
        assertEq(token.code.length, 0);
        assertEq(manager.code.length, 0);
        assertEq(quoter.code.length, 0);

        LaunchFactoryProbe factory = new LaunchFactoryProbe();
        bytes[] memory codes = new bytes[](4);
        bytes32[] memory salts = new bytes32[](4);
        address[] memory predicted = new address[](4);
        for (uint256 i; i < 4; ++i) {
            string memory name =
                vm.parseJsonString(manifest, string.concat(".contracts[", vm.toString(i), "].contract"));
            bytes memory args;
            if (i == 1) {
                args = abi.encode(
                    token,
                    predicted[0],
                    OWNER,
                    vm.parseBytes32(machineArgs[3]),
                    vm.parseUint(machineArgs[4]),
                    vm.parseUint(machineArgs[5])
                );
            } else if (i == 2) {
                args = abi.encode(predicted[1]);
            } else if (i == 3) {
                args =
                    abi.encode(predicted[1], manager, quoter, vm.parseUint(minterArgs[3]), vm.parseUint(minterArgs[4]));
            }
            codes[i] = bytes.concat(vm.getCode(string.concat(name, ".sol:", name)), args);
            salts[i] = keccak256(bytes(name));
            predicted[i] = vm.computeCreate2Address(salts[i], keccak256(codes[i]), address(factory));
        }

        address[] memory deployed = factory.deployAll(codes, salts);
        assertEq(deployed, predicted);
        for (uint256 i; i < deployed.length; ++i) {
            _checkRuntime(deployed[i]);
        }

        IdentityMachine machine = IdentityMachine(deployed[1]);
        MachineViews views = MachineViews(deployed[2]);
        EthMinter minter = EthMinter(deployed[3]);
        assertEq(address(machine.beacon()), deployed[0]);
        assertEq(address(machine.imd()), token);
        assertEq(machine.dev(), OWNER);
        assertTrue(machine.dev() != address(factory));
        assertEq(machine.seatRoot(), vm.parseBytes32(machineArgs[3]));
        assertEq(machine.basePrice(), vm.parseUint(machineArgs[4]));
        assertEq(machine.start(), block.timestamp + vm.parseUint(machineArgs[5]));
        assertEq(Parts(address(machine.inventory())).machine(), address(machine));
        _checkRuntime(address(machine.inventory()));
        assertEq(address(views.machine()), address(machine));
        assertEq(address(views.ledger()), address(machine.inventory()));
        assertEq(address(views.imd()), token);
        assertEq(address(minter.machine()), address(machine));
        assertEq(address(minter.imd()), token);
        assertEq(address(minter.poolManager()), manager);
        assertEq(address(minter.quoter()), quoter);
        assertEq(minter.fee(), vm.parseUint(minterArgs[3]));
        assertEq(uint24(minter.tickSpacing()), vm.parseUint(minterArgs[4]));

        // Absent dependencies defer failure until use, before any payment can move.
        vm.expectRevert(EthMinter.BadPool.selector);
        minter.quote(1);
        vm.deal(OWNER, 1 ether);
        vm.expectRevert(EthMinter.BadPool.selector);
        vm.prank(OWNER);
        minter.mint{value: 1 ether}(1, type(uint256).max, block.timestamp);
        assertEq(OWNER.balance, 1 ether);
        assertEq(machine.minted(), 0);
        assertEq(address(minter).balance, 0);
    }

    function _checkRuntime(address target) private view {
        bytes memory code = target.code;
        assertGt(code.length, 0, "missing runtime");
        assertLe(code.length, 24_576, "runtime exceeds EIP-170");
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden runtime opcode");
        }
    }
}
