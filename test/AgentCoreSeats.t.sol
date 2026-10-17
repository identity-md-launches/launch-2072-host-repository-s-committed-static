// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IdentityMachine} from "../src/IdentityMachine.sol";
import {MachineViews} from "../src/MachineViews.sol";
import {Parts} from "../src/Parts.sol";
import {Catalog} from "../src/art/Catalog.sol";
import {MockIMD, MockBeacon} from "./Mocks.sol";

contract AgentCoreSeatsTest is Test {
    function _claimSeat(uint16 seat) internal {
        address holder = makeAddr("snapshot holder");
        address other = makeAddr("not the snapshot holder");
        bytes32 root = keccak256(bytes.concat(keccak256(abi.encode(seat, holder))));
        IdentityMachine machine = new IdentityMachine(new MockIMD(), new MockBeacon(), holder, root, 0.1 ether, 0);
        MachineViews views = new MachineViews(machine);
        Parts inventory = Parts(address(machine.inventory()));
        bytes32[] memory proof = new bytes32[](0);

        vm.expectRevert(IdentityMachine.BadProof.selector);
        vm.prank(other);
        machine.claimAgentCore(seat, proof);
        assertFalse(machine.seatClaimed(seat));
        assertEq(machine.nextId(), 1);

        vm.prank(holder);
        uint256 id = machine.claimAgentCore(seat, proof);
        assertTrue(machine.seatClaimed(seat));
        assertEq(machine.nextId(), id + 1);
        assertEq(inventory.ownerOf(id), holder);
        assertEq(inventory.totalSupply(), 1);
        (uint16 design,,,,,, uint24 storedSeat, uint112 plug) = machine.parts(id);
        assertEq(design, Catalog.AGENT_CORE);
        assertEq(storedSeat, uint256(seat) + 1);
        assertEq(plug, 0);
        (uint256[] memory ids, uint16[] memory designs, uint24[] memory seats, uint256[] memory plugs) =
            views.inventory(holder, 0, machine.nextId());
        assertEq(ids.length, 1);
        assertEq(ids[0], id);
        assertEq(designs[0], Catalog.AGENT_CORE);
        assertEq(seats[0], uint256(seat) + 1);
        assertEq(plugs[0], 0);

        vm.expectRevert(IdentityMachine.SeatClaimed.selector);
        vm.prank(holder);
        machine.claimAgentCore(seat, proof);
        assertEq(inventory.totalSupply(), 1);
        assertEq(machine.nextId(), id + 1);
    }

    function test_maximumSeatCanBeClaimedAndRead() public {
        _claimSeat(type(uint16).max);
    }

    function test_zeroSeatDoesNotUseTheNoSeatSentinel() public {
        _claimSeat(0);
    }

    function testFuzz_everyUint16SeatCanBeClaimed(uint16 seat) public {
        _claimSeat(seat);
    }
}
