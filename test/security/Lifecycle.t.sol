// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IdentityMachine} from "../../src/IdentityMachine.sol";
import {DrandBeacon} from "../../src/DrandBeacon.sol";
import {Shapes} from "../../src/Shapes.sol";
import {Catalog} from "../../src/art/Catalog.sol";
import {MockBeacon} from "../Mocks.sol";
import {Base, G} from "../Base.sol";

contract SecurityLifecycleTest is Base {
    /// Hash affected accounting, items, pending records, geometry, archive and token balances.
    function _state(uint256[] memory ids) internal view returns (bytes32 h) {
        h = keccak256(
            abi.encode(
                views.status(alice, ids),
                views.roundInfo(1),
                views.roundInfo(2),
                parts.totalSupply(),
                imd.balanceOf(address(m)),
                imd.balanceOf(alice),
                imd.balanceOf(bob),
                imd.balanceOf(DEAD),
                imd.balanceOf(devAddr),
                m.reserve(),
                m.devBalance(),
                m.order(1, 1),
                m.order(1, 2)
            )
        );
        for (uint256 i; i < ids.length; ++i) {
            uint256 id = ids[i];
            (address owner, uint48 dr) = m.pending(id);
            (uint16 d, uint8 rot, uint8 place, uint32 r, int32 x, int32 y, uint24 seat, uint112 plug) = m.parts(id);
            address inventoryOwner;
            try parts.ownerOf(id) returns (address who) {
                inventoryOwner = who;
            } catch {}
            h = keccak256(
                abi.encode(
                    h,
                    id,
                    owner,
                    dr,
                    d,
                    rot,
                    place,
                    r,
                    x,
                    y,
                    seat,
                    plug,
                    inventoryOwner,
                    m.placerOf(id),
                    m.credit(id),
                    m.earned(id)
                )
            );
        }
    }

    function test_mintPriceFailureRollsBackTentativeRoundEndAndExtras() public {
        for (uint256 i; i < 75; ++i) {
            _mint(bob, 20);
        }
        uint256 winner = _grant(alice, G.CAP);
        _place(alice, winner, 0, 0, -2);
        vm.warp(_round().deadline);
        uint256 next = m.nextId();
        uint256[] memory watched = _ids(winner, next);
        bytes32 before = _state(watched);
        vm.expectRevert(IdentityMachine.TooExpensive.selector);
        vm.prank(bob);
        m.mint(1, BASE - 1);
        assertEq(_state(watched), before);
        _mint(bob, 1);
        assertEq(m.round(), 2);
        assertEq(_round().minted, 1);
    }

    function test_mintTransferFailureRollsBackTentativeRoundEnd() public {
        uint256 id = _grant(alice, G.CAP);
        _place(alice, id, 0, 0, -2);
        _mint(bob, 2);
        vm.warp(_round().deadline);
        vm.prank(bob);
        imd.approve(address(m), 0);
        bytes32 before = _state(_ids(id, m.nextId()));
        vm.expectRevert();
        vm.prank(bob);
        m.mint(1, BASE);
        assertEq(_state(_ids(id, m.nextId())), before);
        vm.prank(bob);
        imd.approve(address(m), BASE);
        _mint(bob, 1);
        assertEq(m.round(), 2);
    }

    function test_revealLateFailureRollsBackEarlierItemIssue() public {
        (uint256 a,) = _mint(alice, 1);
        vm.warp(_now() + 3);
        (uint256 b,) = _mint(bob, 1);
        _rig(a, G.PATCH);
        bytes32 before = _state(_ids(a, b));
        vm.expectRevert(IdentityMachine.NotReady.selector);
        m.reveal(_ids(a, b));
        assertEq(_state(_ids(a, b)), before);
        _rig(b, G.PATCH);
        m.reveal(_ids(a, b));
        assertEq(parts.ownerOf(a), alice);
        assertEq(parts.ownerOf(b), bob);
        assertEq(parts.totalSupply(), 2);
    }

    function test_failedBuildRollsBackRealProofRevealsAndGeometry() public {
        // Real, published evmnet signature: this tests transactional cache rollback, not mock verification.
        uint64 dr = 21_238_365;
        bytes memory sig =
            hex"2e6586e88e308d252d93f2775068735df1557cfcd5ab71661abacdddc864147c0fe3c18439c99ee9fb8515d2a908ca08b6e38669272c5699614e517c4ae895d1";
        beacon = MockBeacon(address(new DrandBeacon()));
        vm.warp(beacon.timeOf(dr - 3)); // a mint now selects dr (DRAND_MARGIN)
        _deploy();
        vm.prank(alice);
        imd.approve(address(m), type(uint256).max);
        (uint256 a,) = _mint(alice, 2);
        uint256 seed = uint256(keccak256(abi.encode(keccak256(sig), a)));
        uint8 tier = m.rollTier(seed);
        uint16 d = Catalog.partFor(tier, Shapes.rollDrop(tier, seed >> 16), seed >> 32);
        (bool fits, uint8 rot, int32 x, int32 y) = _findSpot(d);
        assertTrue(fits);
        IdentityMachine.Proof[] memory proofs = new IdentityMachine.Proof[](1);
        proofs[0] = IdentityMachine.Proof(dr, sig);
        IdentityMachine.Spot[] memory spots = new IdentityMachine.Spot[](2);
        spots[0] = IdentityMachine.Spot(a, rot, x, y);
        spots[1] = IdentityMachine.Spot(a + 1, 4, x, y);
        bytes32 before = _state(_ids(a, a + 1));
        vm.expectRevert(IdentityMachine.BadRot.selector);
        vm.prank(alice);
        m.build(1, proofs, _ids(a, a + 1), spots);
        assertEq(beacon.randomness(dr), bytes32(0), "proof cache rolled back");
        assertEq(_state(_ids(a, a + 1)), before);
        vm.prank(alice);
        m.build(1, proofs, _ids(a, a + 1), _spots1(a, rot, x, y));
        assertEq(beacon.randomness(dr), keccak256(sig));
        assertEq(m.placerOf(a), alice);
        assertEq(parts.ownerOf(a + 1), alice);
    }

    function test_giftOwnershipPlacementAndPermanentClaimRights() public {
        uint256 before = imd.balanceOf(alice);
        vm.prank(alice);
        (uint256 id, uint256 price) = m.mintFor(bob, 1, BASE);
        assertEq(before - imd.balanceOf(alice), price);
        _rig(id, G.PATCH);
        vm.prank(carol);
        m.reveal(_ids(id));
        assertEq(parts.ownerOf(id), bob);
        vm.prank(bob);
        (bool ok,) =
            address(parts).call(abi.encodeWithSignature("transferFrom(address,address,uint256)", bob, carol, id));
        assertFalse(ok);
        _place(bob, id, 1, 0, -2);
        m.sponsor(1 ether);
        address[2] memory outsiders = [alice, carol];
        for (uint256 i; i < outsiders.length; ++i) {
            vm.expectRevert(IdentityMachine.NotOwner.selector);
            vm.prank(outsiders[i]);
            m.claim(_ids(id));
        }
        vm.prank(bob);
        assertEq(m.claim(_ids(id)), 1 ether);
        assertEq(m.placerOf(id), bob);
    }

    function testFuzz_approvalsCannotTransferOrPlaceItems(bool blanket) public {
        uint256 id = _grant(alice, G.CAP);
        bytes memory approval = blanket
            ? abi.encodeWithSignature("setApprovalForAll(address,bool)", bob, true)
            : abi.encodeWithSignature("approve(address,uint256)", bob, id);
        vm.prank(alice);
        (bool ok,) = address(parts).call(approval);
        assertFalse(ok);
        bytes32 before = _state(_ids(id));
        vm.expectRevert(IdentityMachine.NotOwner.selector);
        vm.prank(bob);
        m.build(1, noProofs, noIds, _spots1(id, 0, 0, -2));
        assertEq(_state(_ids(id)), before);
        assertEq(parts.ownerOf(id), alice);
    }

    function test_claimForeignLastIdRollsBackPriorCreditsAndDebt() public {
        uint256 a = _grant(alice, G.CAP);
        uint256 b = _grant(bob, G.CAP);
        _place(alice, a, 0, -1, -2);
        _place(bob, b, 0, 1, -2);
        m.sponsor(3 ether + 1);
        bytes32 before = _state(_ids(a, b));
        vm.expectRevert(IdentityMachine.NotOwner.selector);
        vm.prank(alice);
        m.claim(_ids(a, b));
        assertEq(_state(_ids(a, b)), before);
        uint256 e = m.earned(a);
        vm.prank(alice);
        assertEq(m.claim(_ids(a)), e);
    }

    function test_claimTransferFailureRestoresDebtAndCreditForRetry() public {
        uint256 id = _grant(alice, G.CROSS);
        _place(alice, id, 0, 0, -2);
        uint256 child = _grantPlug(bob, G.CAP, 101);
        _place(bob, child, 0, 0, -3);
        m.sponsor(1 ether + 1);
        bytes32 before = _state(_ids(id, child));
        vm.mockCallRevert(address(imd), abi.encodeWithSelector(IERC20.transfer.selector, alice), "transfer unavailable");
        vm.expectRevert();
        vm.prank(alice);
        m.claim(_ids(id));
        assertEq(_state(_ids(id, child)), before);
        vm.clearMockedCalls();
        uint256 e = m.earned(id);
        vm.prank(alice);
        assertEq(m.claim(_ids(id)), e);
        assertEq(m.credit(id), 0);
    }

    function test_deadlineFundingRoutesToReserveAndMatchesOnlyOnce() public {
        m.fundPot(3 ether);
        uint256 deadline = _round().deadline;
        vm.warp(deadline - 1);
        m.fundPot(2 ether);
        assertEq(_round().pot, 5 ether);
        vm.warp(deadline);
        m.fundPot(7 ether);
        assertEq(_round().pot, 5 ether);
        assertEq(m.reserve(), 7 ether);
        vm.expectRevert(IdentityMachine.RoundOver.selector);
        m.sponsor(1);
        m.endRound();
        assertEq(m.reserve(), 7 ether, "late funding stays in the reserve");
        assertEq(_round().pot, 5 ether, "the unclaimed pot (no places) starts round 2");
        _mint(bob, 1);
        uint256 matched = BASE * 1500 / 10_000;
        assertEq(m.reserve(), 7 ether - matched + BASE * 500 / 10_000, "matched once, plus the mint's 5%");
        assertEq(views.roundInfo(1).pot, 5 ether);
        assertEq(_round().pot, 5 ether + BASE * 4100 / 10_000 + matched);
    }

    function test_invalidTrailingSpotAndUnreadyRevealAbortTheWholeBuild() public {
        uint256 first = _grant(alice, G.PATCH);
        uint256 spare = _grant(alice, G.CAP);
        (uint256 pending,) = _mint(alice, 1);
        IdentityMachine.Spot[] memory spots = new IdentityMachine.Spot[](2);
        spots[0] = IdentityMachine.Spot(first, 0, 2, 0);
        spots[1] = IdentityMachine.Spot(spare, 255, 0, 0);
        bytes32 before = _state(_ids(first, pending));
        vm.expectRevert(IdentityMachine.NotReady.selector);
        vm.prank(alice);
        m.build(1, noProofs, _ids(pending), spots);
        assertEq(_state(_ids(first, pending)), before);
        _rig(pending, G.PATCH);
        before = _state(_ids(first, pending));
        vm.expectRevert(IdentityMachine.BadRot.selector);
        vm.prank(alice);
        m.build(1, noProofs, _ids(pending), spots);
        assertEq(_state(_ids(first, pending)), before);
        assertEq(m.round(), 1);
        assertEq(parts.ownerOf(spare), alice);
        (address owner,) = m.pending(pending);
        assertEq(owner, alice);
        assertEq(m.placerOf(first), address(0));
    }

    function _microClaims(uint256[] memory ids, bool often) internal returns (uint256[] memory paid) {
        paid = new uint256[](ids.length);
        for (uint256 i = 1; i <= 97; ++i) {
            m.sponsor(i);
            if (often) {
                for (uint256 j; j < ids.length; ++j) {
                    vm.prank(alice);
                    paid[j] += m.claim(_ids(ids[j]));
                }
            }
        }
        for (uint256 j; j < ids.length; ++j) {
            vm.prank(alice);
            paid[j] += m.claim(_ids(ids[j]));
            paid[j] += m.earned(ids[j]);
        }
    }

    function test_frequentClaimsPreserveFractionalDebtForEveryWeight() public {
        uint16[4] memory designs = [G.CAP, G.REEL, G.RADAR, G.CONSOLE];
        uint256[] memory ids = new uint256[](4);
        for (uint256 i; i < ids.length; ++i) {
            ids[i] = _grant(alice, designs[i]);
            _placeAnywhere(alice, ids[i]);
        }
        uint256 snap = vm.snapshotState();
        uint256[] memory frequent = _microClaims(ids, true);
        vm.revertToState(snap);
        uint256[] memory once = _microClaims(ids, false);
        assertEq(frequent, once);
    }

    function test_latePlacementCannotClaimEarlierSharedIncome() public {
        uint256 a = _grant(alice, G.CAP);
        _place(alice, a, 0, -1, -2);
        m.sponsor(101);
        uint256 b = _grant(bob, G.CAP);
        _place(bob, b, 0, 1, -2);
        assertEq(m.earned(b), 0);
        m.sponsor(11);
        assertEq(m.earned(a), 106);
        assertEq(m.earned(b), 5);
    }

    function test_claimAcrossOldAndCurrentRoundsWithDuplicates() public {
        uint256 oldId = _grant(alice, G.CAP);
        _place(alice, oldId, 0, 0, -2);
        m.sponsor(101);
        vm.warp(_round().deadline);
        m.endRound();
        uint256 newId = _grant(alice, G.CAP);
        _place(alice, newId, 0, 0, -2);
        m.sponsor(103);
        uint256[] memory ids = new uint256[](4);
        (ids[0], ids[1], ids[2], ids[3]) = (newId, oldId, newId, oldId);
        vm.prank(alice);
        assertEq(m.claim(ids), 204);
        assertEq(m.earned(oldId) + m.earned(newId), 0);
    }

    function test_agentCoreProofBindsCallerAndCannotReplay() public {
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leafBob;
        vm.expectRevert(IdentityMachine.BadProof.selector);
        vm.prank(carol);
        m.claimAgentCore(1723, proof);
        assertFalse(m.seatClaimed(1723));
        uint256 next = m.nextId();
        vm.prank(alice);
        uint256 id = m.claimAgentCore(1723, proof);
        assertEq(id, next);
        assertEq(_design(id), G.AGENT_CORE);
        assertEq(_plugOf(id), 0);
        assertEq(m.minted(), 0);
        vm.expectRevert(IdentityMachine.SeatClaimed.selector);
        vm.prank(alice);
        m.claimAgentCore(1723, proof);
        assertEq(m.nextId(), next + 1);
    }

    function test_staleBuildAndExactDeadlineNeverPlaceIntoNextRound() public {
        uint256 id = _grant(alice, G.CAP);
        vm.warp(_round().deadline);
        vm.expectRevert(IdentityMachine.RoundOver.selector);
        vm.prank(alice);
        m.build(1, noProofs, noIds, _spots1(id, 0, 0, -2));
        m.endRound();
        vm.expectRevert(IdentityMachine.RoundOver.selector);
        vm.prank(alice);
        m.build(1, noProofs, noIds, _spots1(id, 0, 0, -2));
        assertEq(parts.ownerOf(id), alice);
        _place(alice, id, 0, 0, -2);
        assertEq(_machineOf(id), 2);
    }

    function test_emptyClaimAndRepeatedRevealCannotCreateValue() public {
        uint256 id = _get(alice, G.PATCH);
        bytes32 before = _state(_ids(id));
        vm.startPrank(alice);
        m.claim(noIds);
        m.reveal(_ids(id, type(uint256).max));
        vm.stopPrank();
        assertEq(_state(_ids(id)), before);
    }

    function test_directDonationCreatesSurplusWithoutNewLiability() public {
        uint256 beforePot = _round().pot;
        uint256 beforeReserve = m.reserve();
        imd.transfer(address(m), 101);
        assertEq(m.reserve(), beforeReserve);
        assertEq(_round().pot, beforePot);
        assertEq(m.price(), BASE);
        assertEq(imd.balanceOf(address(m)), 101);
        uint256 id = _get(alice, G.PATCH);
        _place(alice, id, 1, 0, -2);
        assertEq(m.earned(id), 0, "the donation gives no withdrawal right");
    }

    function test_payDevFailurePreservesBalanceAndAnyonePaysOnlyDeveloper() public {
        _mint(alice, 3);
        uint256 due = m.devBalance();
        vm.mockCallRevert(
            address(imd), abi.encodeWithSelector(IERC20.transfer.selector, devAddr), "transfer unavailable"
        );
        vm.expectRevert();
        m.payDev();
        assertEq(m.devBalance(), due);
        vm.clearMockedCalls();
        uint256 callerBefore = imd.balanceOf(carol);
        vm.prank(carol);
        m.payDev();
        assertEq(imd.balanceOf(devAddr), due);
        assertEq(imd.balanceOf(carol), callerBefore);
        assertEq(m.devBalance(), 0);
    }
}
