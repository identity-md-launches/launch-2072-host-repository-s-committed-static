// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MachineViews} from "../../src/MachineViews.sol";
import {Base, G} from "../Base.sol";

contract SecurityViewsTest is Base {
    function _earner(address who, int32 x) internal returns (uint256 id) {
        id = _grant(who, G.CROSS);
        _place(who, id, 0, x, -2);
    }

    function test_claimableDeduplicatesAndMatchesActualPayment() public {
        uint256 a = _earner(alice, -1);
        uint256 b = _earner(alice, 1);
        m.sponsor(17 ether + 1);
        uint256[] memory input = new uint256[](5);
        (input[0], input[1], input[2], input[3], input[4]) = (b, a, b, a, b);
        (uint256[] memory ids, uint256 quoted) = views.claimable(alice, input);
        assertEq(ids.length, 2, "one entry per payable part");
        assertEq(quoted, m.earned(a) + m.earned(b));
        vm.prank(alice);
        assertEq(m.claim(input), quoted, "view total must be executable");
        (, quoted) = views.claimable(alice, input);
        assertEq(quoted, 0);
    }

    function test_statusCountsEachPartOnce() public {
        uint256 id = _earner(alice, 0);
        m.sponsor(1 ether);
        assertEq(views.status(alice, _ids(id, id)).earned, m.earned(id));
    }

    function test_claimableFiltersForeignUnplacedUnknownAndZeroIds() public {
        uint256 a = _earner(alice, -1);
        uint256 b = _earner(bob, 1);
        uint256 unplaced = _grant(alice, G.CAP);
        m.sponsor(9 ether);
        uint256[] memory input = new uint256[](6);
        (input[0], input[1], input[2], input[3], input[4], input[5]) = (b, unplaced, 0, type(uint256).max, a, a);
        (uint256[] memory ids, uint256 total) = views.claimable(alice, input);
        assertEq(ids.length, 1);
        assertEq(ids[0], a);
        assertEq(total, m.earned(a));
        (ids, total) = views.claimable(address(0), input);
        assertEq(ids.length, 0);
        assertEq(total, 0);
    }

    function test_statusOfZeroAddressHasNoWalletBalances() public view {
        MachineViews.Status memory s = views.status(address(0), noIds);
        assertEq(s.balance, 0);
        assertEq(s.allowance, 0);
        assertEq(s.inventory, 0);
        assertEq(s.earned, 0);
        assertEq(s.round, 1);
        assertEq(s.open, 12);
    }

    function test_inventoryOversizedPageClampsWithoutOverflow() public {
        uint256 id = _grant(alice, G.CAP);
        (uint256[] memory ids,,,) = views.inventory(alice, 1, type(uint256).max);
        assertEq(ids.length, 1);
        assertEq(ids[0], id);
        (ids,,,) = views.inventory(alice, type(uint256).max, type(uint256).max);
        assertEq(ids.length, 0);
    }

    function test_pendingOversizedPageClampsWithoutOverflow() public {
        (uint256 id,) = _mint(alice, 1);
        (uint256[] memory ids, uint64[] memory dr) = views.pendingOf(alice, 1, type(uint256).max);
        assertEq(ids.length, 1);
        assertEq(ids[0], id);
        assertEq(dr.length, ids.length);
        (ids,) = views.pendingOf(alice, type(uint256).max, type(uint256).max);
        assertEq(ids.length, 0);
    }

    function test_archiveOversizedPageClampsWithoutOverflow() public {
        vm.warp(_round().deadline);
        m.endRound();
        MachineViews.RoundInfo[] memory rows = views.archive(1, type(uint256).max);
        assertEq(rows.length, 2);
        assertGt(rows[0].ended, 0);
        assertEq(rows[1].ended, 0);
        assertEq(views.archive(type(uint256).max, type(uint256).max).length, 0);
    }

    function test_boardOversizedPageClampsWithoutOverflow() public {
        uint256 id = _earner(alice, 0);
        uint256[] memory board = views.board(1, 1, type(uint256).max);
        assertEq(board.length, 2);
        assertEq(uint64(board[1]), id);
        assertEq(views.board(1, type(uint256).max, type(uint256).max).length, 0);
    }

    function test_emptyAndZeroPages() public view {
        assertEq(views.board(1, 0, 0).length, 0);
        assertEq(views.archive(0, 0).length, 0);
        (uint256[] memory ids,,,) = views.inventory(alice, 0, 0);
        assertEq(ids.length, 0);
        (ids,) = views.pendingOf(alice, 0, 0);
        assertEq(ids.length, 0);
        (ids,) = views.pendingOf(address(0), 0, 100);
        assertEq(ids.length, 0);
    }

    function test_boardPackingPreservesSignedCoordinatesAndPlacer() public {
        uint256 id = _grant(alice, G.CAP);
        _place(alice, id, 3, -2, -1);
        uint256[] memory words = views.board(1, 0, 100);
        assertEq(words.length, 2);
        assertEq(address(uint160(words[0])), alice);
        assertEq(uint16(words[0] >> 160), G.CAP);
        assertEq(uint8(words[0] >> 176), 3);
        assertEq(uint64(words[1]), id);
        assertEq(int32(uint32(words[1] >> 64)), -2);
        assertEq(int32(uint32(words[1] >> 96)), -1);
    }

    function test_inventoryParallelArraysTrimAfterForeignOwnershipAndPlacement() public {
        uint256 a = _grantPlug(alice, G.CAP, 13);
        uint256 b = _grantPlug(bob, G.CAP, 17);
        uint256 c = _grantPlug(alice, G.CAP, 19);
        assertEq(parts.ownerOf(b), bob);
        _place(alice, a, 0, 0, -2);
        (uint256[] memory ids, uint16[] memory ds, uint24[] memory seats, uint256[] memory plugs) =
            views.inventory(alice, 0, 100);
        assertEq(ids.length, 1);
        assertEq(ids[0], c);
        assertEq(ds.length, 1);
        assertEq(seats.length, 1);
        assertEq(plugs.length, 1);
        assertEq(ds[0], G.CAP);
        assertEq(seats[0], 0);
        assertEq(plugs[0], 19);
    }

    function testFuzz_paginationMatchesAvailableIds(uint256 from, uint256 n) public {
        for (uint256 i; i < 3; ++i) {
            _grant(alice, G.CAP);
        }
        (uint256[] memory ids,,,) = views.inventory(alice, from, n);
        uint256 expected;
        for (uint256 id = 1; id < 4; ++id) {
            if (id >= from && id - from < n) ++expected;
        }
        assertEq(ids.length, expected);
    }
}
