// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IdentityMachine} from "src/IdentityMachine.sol";
import {EthMinter} from "src/EthMinter.sol";
import {Shapes} from "src/Shapes.sol";
import {Catalog} from "src/art/Catalog.sol";
import {ManifestFixture} from "./ManifestFixture.sol";

contract RejectingCheckoutWallet {
    EthMinter private immutable checkout;

    constructor(EthMinter c) {
        checkout = c;
    }

    function buy(uint256 count, uint256 maximum) external payable returns (uint256, uint256) {
        return checkout.mintWithReferral{value: msg.value}(count, maximum, block.timestamp, address(this));
    }

    receive() external payable {
        revert("refund rejected");
    }
}

contract ManifestLaunchBehaviorTest is ManifestFixture {
    // Existing committed evmnet vector from test/audit/Beacon.t.sol. No RPC or signature generation.
    uint64 private constant PROVEN_ROUND = 21_238_365;
    bytes private constant SIGNATURE =
        hex"2e6586e88e308d252d93f2775068735df1557cfcd5ab71661abacdddc864147c0fe3c18439c99ee9fb8515d2a908ca08b6e38669272c5699614e517c4ae895d1";
    address private buyer;
    address private stranger;

    function setUp() public {
        // Deployment time is chosen so opening + 9 seconds coincides with the recorded public signature.
        _deployManifest(1_727_521_075 + (uint256(PROVEN_ROUND) - 1) * 3 - 9 - 172800);
        buyer = makeAddr("manifest behavior buyer");
        stranger = makeAddr("manifest behavior stranger");
        _fundActor(buyer);
        _fundActor(stranger);
    }

    function _buy(address payer, uint256 n) private returns (uint256 first, uint256 total) {
        uint256 cost;
        (total, cost) = checkout.quote(n);
        vm.prank(payer);
        (first,) = checkout.mint{value: cost}(n, total, vm.getBlockTimestamp());
    }

    function test_countdownRejectsAllCreationAndRollsBackSettledCheckout() public {
        uint256 opening = machine.start();
        vm.warp(opening - 1);
        (uint256 total, uint256 cost) = checkout.quote(1);
        uint256 beforeBalance = buyer.balance;
        vm.expectRevert(IdentityMachine.NotStarted.selector);
        vm.prank(buyer);
        checkout.mint{value: cost}(1, total, opening);
        vm.expectRevert(IdentityMachine.NotStarted.selector);
        vm.prank(buyer);
        machine.mint(1, total);
        vm.expectRevert(IdentityMachine.NotStarted.selector);
        _claimCore();
        vm.expectRevert(IdentityMachine.NotStarted.selector);
        machine.build(
            1,
            new IdentityMachine.Proof[](0),
            new uint256[](0),
            new IdentityMachine.Spot[](0),
            IdentityMachine.GrowthExit(0, -1, 1)
        );
        assertEq(buyer.balance, beforeBalance);
        assertEq(pool.swaps(), 0);
        assertEq(pool.ethSettled(), 0);
        assertEq(token.balanceOf(address(pool)), POOL_TOKENS);
        assertEq(address(checkout).balance, 0);
        assertEq(token.balanceOf(address(checkout)), 0);
        assertEq(token.allowance(address(checkout), address(machine)), 0);
        assertEq(machine.nextId(), 1);
        assertFalse(machine.seatClaimed(seat));

        vm.warp(opening);
        (uint256 first,) = _buy(buyer, 1);
        assertEq(first, 1);
        assertEq(machine.minted(), 1);
        assertEq(_claimCore(), 2);
        assertEq(machine.dev(), LAUNCH_DEV);
    }

    function test_realProofRevealAndPlacementAreAtomicWithManifestDependencies() public {
        vm.warp(machine.start());
        (uint256 first,) = _buy(buyer, 8);
        uint256[] memory ids = new uint256[](8);
        for (uint256 i; i < ids.length; ++i) {
            ids[i] = first + i;
        }
        (, uint48 dr) = machine.pending(first);
        assertEq(dr, PROVEN_ROUND);
        vm.expectRevert(IdentityMachine.NotReady.selector);
        machine.reveal(ids);
        vm.warp(beacon.timeOf(PROVEN_ROUND));

        // Discover a placement using public queries, then replay from the genuinely unproven state.
        uint256 snapshot = vm.snapshotState();
        beacon.prove(PROVEN_ROUND, SIGNATURE);
        machine.reveal(ids);
        (IdentityMachine.Spot memory spot, IdentityMachine.GrowthExit memory exit) = _fittingSpot(ids);
        assertTrue(vm.revertToState(snapshot));
        IdentityMachine.Proof[] memory proofs = new IdentityMachine.Proof[](1);
        proofs[0] = IdentityMachine.Proof(PROVEN_ROUND, SIGNATURE);
        IdentityMachine.Spot[] memory spots = new IdentityMachine.Spot[](1);
        spots[0] = spot;

        vm.expectRevert(IdentityMachine.NotOwner.selector);
        vm.prank(stranger);
        machine.build(1, proofs, ids, spots, exit);
        _assertUnrevealed(ids);

        vm.expectRevert(IdentityMachine.NoGrowthExit.selector);
        vm.prank(buyer);
        machine.build(1, proofs, ids, spots, IdentityMachine.GrowthExit(0, 0, 0));
        _assertUnrevealed(ids);

        vm.prank(buyer);
        machine.build(1, proofs, ids, spots, exit);
        assertEq(beacon.randomness(PROVEN_ROUND), keccak256(SIGNATURE));
        assertEq(beacon.latest(), PROVEN_ROUND);
        assertEq(machine.placerOf(spot.id), buyer);
        assertEq(inventory.balanceOf(buyer), 7);
        assertEq(inventory.balanceOf(stranger), 0);
        assertEq(inventory.totalSupply(), 7);
        assertEq(views.roundInfo(1).placed, 1);
        for (uint256 i; i < ids.length; ++i) {
            (address owner,) = machine.pending(ids[i]);
            assertEq(owner, address(0));
            if (ids[i] != spot.id) assertEq(inventory.ownerOf(ids[i]), buyer);
        }
        // Permissionless repeat reveal cannot resurrect the consumed item or increase supply.
        vm.prank(stranger);
        machine.reveal(ids);
        assertEq(inventory.totalSupply(), 7);
    }

    function _assertUnrevealed(uint256[] memory ids) private view {
        assertEq(beacon.latest(), 0, "a failed build must roll back the external beacon too");
        assertEq(beacon.randomness(PROVEN_ROUND), bytes32(0));
        assertEq(inventory.totalSupply(), 0);
        assertEq(views.roundInfo(1).placed, 0);
        for (uint256 i; i < ids.length; ++i) {
            (address owner, uint48 dr) = machine.pending(ids[i]);
            assertEq(owner, buyer);
            assertEq(dr, PROVEN_ROUND);
            assertEq(machine.placerOf(ids[i]), address(0));
        }
    }

    function _fittingSpot(uint256[] memory ids)
        private
        view
        returns (IdentityMachine.Spot memory spot, IdentityMachine.GrowthExit memory exit)
    {
        for (uint256 i; i < ids.length; ++i) {
            (uint16 design,,,,,,,) = machine.parts(ids[i]);
            for (uint8 rot; rot < 4; ++rot) {
                for (int32 x = -3; x <= 3; ++x) {
                    for (int32 y = -3; y <= 3; ++y) {
                        try machine.check(design, rot, x, y) {
                            (uint8 n, int32[9] memory xs, int32[9] memory ys,) =
                                Shapes.footprint(Catalog.tmplOf(design), rot, x, y);
                            int32 minX = -1;
                            int32 minY = -1;
                            int32 maxX = 1;
                            int32 maxY = 1;
                            for (uint256 j; j < n; ++j) {
                                if (xs[j] < minX) minX = xs[j];
                                if (xs[j] > maxX) maxX = xs[j];
                                if (ys[j] < minY) minY = ys[j];
                                if (ys[j] > maxY) maxY = ys[j];
                            }
                            // Preserve a known core socket on an unchanged bounding edge.
                            if (minY == -1) exit = IdentityMachine.GrowthExit(0, -1, 1);
                            else if (maxX == 1) exit = IdentityMachine.GrowthExit(1, 0, 2);
                            else if (maxY == 1) exit = IdentityMachine.GrowthExit(0, 1, 4);
                            else if (minX == -1) exit = IdentityMachine.GrowthExit(-1, 0, 8);
                            else continue;
                            return (IdentityMachine.Spot(ids[i], rot, x, y), exit);
                        } catch {}
                    }
                }
            }
        }
        revert("committed drand vector supplied no valid placement");
    }

    function test_rejectedRefundRollsBackRolloverPrizeAndReferralThenExactPaymentWorks() public {
        vm.warp(machine.start());
        uint256 core = _claimCore();
        _placeCore(core);
        _buy(buyer, 2);
        uint256 oldPot = views.roundInfo(1).pot;
        uint256 oldNext = machine.nextId();
        uint256 oldPoolTokens = token.balanceOf(address(pool));
        uint256 oldSettled = pool.ethSettled();
        uint256 oldMachineBalance = token.balanceOf(address(machine));
        vm.warp(views.roundInfo(1).deadline);
        RejectingCheckoutWallet wallet = new RejectingCheckoutWallet(checkout);
        (uint256 total, uint256 cost) = checkout.quote(1);
        vm.deal(address(this), cost + 1);
        vm.expectRevert(EthMinter.RefundFailed.selector);
        wallet.buy{value: cost + 1}(1, total);
        assertEq(address(this).balance, cost + 1);
        assertEq(machine.round(), 1);
        assertEq(machine.nextId(), oldNext);
        assertEq(views.roundInfo(1).pot, oldPot);
        assertEq(views.roundInfo(1).ended, 0);
        assertEq(machine.credit(core), 0);
        assertEq(machine.totalWon(), 0);
        assertEq(machine.referralBalance(address(wallet)), 0);
        assertEq(token.balanceOf(address(pool)), oldPoolTokens);
        assertEq(token.balanceOf(address(machine)), oldMachineBalance);
        assertEq(pool.ethSettled(), oldSettled);
        assertEq(address(checkout).balance, 0);
        assertEq(token.balanceOf(address(checkout)), 0);
        assertEq(token.allowance(address(checkout), address(machine)), 0);

        (uint256 first, uint256 paid) = wallet.buy{value: cost}(1, total);
        assertEq(first, oldNext);
        assertEq(paid, cost);
        assertEq(machine.round(), 2);
        assertGt(machine.credit(core), 0);
        assertEq(machine.referralBalance(address(wallet)), total * 3 / 100);
        (address owner,) = machine.pending(first);
        assertEq(owner, address(wallet));
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_interveningPurchaseInvalidatesOnlyTheOldQuote(uint256 count, uint256 intervening) public {
        vm.warp(machine.start());
        uint256 n = bound(count, 1, 200);
        uint256 otherN = bound(intervening, 1, 200);
        (uint256 staleTotal, uint256 staleEth) = checkout.quote(n);
        _buy(stranger, otherN);
        uint256 beforeBalance = buyer.balance;
        uint256 beforePoolTokens = token.balanceOf(address(pool));
        vm.expectRevert(EthMinter.TooExpensive.selector);
        vm.prank(buyer);
        checkout.mint{value: staleEth}(n, staleTotal, vm.getBlockTimestamp());
        assertEq(buyer.balance, beforeBalance);
        assertEq(machine.minted(), otherN);
        assertEq(token.balanceOf(address(pool)), beforePoolTokens);
        assertEq(pool.swaps(), 1);
        (uint256 first, uint256 currentTotal) = _buy(buyer, n);
        assertGt(currentTotal, staleTotal);
        assertEq(first, otherN + 1);
        assertEq(machine.minted(), otherN + n);
        assertEq(token.allowance(address(checkout), address(machine)), 0);
    }
}
