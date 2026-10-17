// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Arrays} from "@openzeppelin/contracts/utils/Arrays.sol";
import {IdentityMachine} from "./IdentityMachine.sol";

interface IPartsView {
    function ownerOf(uint256 id) external view returns (address);
    function balanceOf(address who) external view returns (uint256);
}

/// @title Identity Machine views
/// @notice Read-only helpers so a UI or agent can load the game in a few calls. Holds nothing and changes nothing;
///         split out of the machine to keep it under the contract size limit.
contract MachineViews {
    IdentityMachine public immutable machine;
    IPartsView public immutable ledger;
    IERC20 public immutable imd;

    struct Status {
        uint256 time;
        uint256 start;
        uint256 round;
        uint256 begin; // of the running round
        uint256 deadline;
        uint256 roundMinted;
        uint256 placed;
        uint256 open; // open sockets
        uint256 pot;
        uint256 reserve;
        uint256 price;
        uint256 minted; // all rounds
        uint256 nextId; // ids run 1 .. nextId - 1
        uint256 totalWeight;
        uint256 totalPaid;
        uint256 totalWon;
        uint256 earned; // by the parts `ids`
        uint256 balance; // `who`'s IMD
        uint256 allowance; // `who`'s IMD the machine may take
        uint256 inventory; // `who`'s inventory items
    }

    struct RoundInfo {
        uint256 begin;
        uint256 deadline;
        uint256 ended;
        uint256 minted;
        uint256 placed;
        uint256 open;
        int32 minX;
        int32 minY;
        int32 maxX;
        int32 maxY;
        uint256 pot;
        uint256 prize;
    }

    constructor(IdentityMachine machine_) {
        machine = machine_;
        ledger = IPartsView(address(machine_.inventory()));
        imd = machine_.imd();
    }

    /// @notice The running round, the game's totals and `who`'s balances in one call. `ids`: distinct parts to sum
    ///         `earned` over; duplicate ids count once (send them in chunks for large holdings).
    function status(address who, uint256[] calldata ids) external view returns (Status memory s) {
        IdentityMachine m = machine;
        s.time = block.timestamp;
        s.start = m.start();
        s.round = m.round();
        RoundInfo memory r = roundInfo(s.round);
        s.begin = r.begin;
        s.deadline = r.deadline;
        s.roundMinted = r.minted;
        s.placed = r.placed;
        s.open = r.open;
        s.pot = r.pot;
        s.reserve = m.reserve();
        s.price = m.price();
        s.minted = m.minted();
        s.nextId = m.nextId();
        (,,,,,,,,,, uint128 tw,,,) = m.rounds(s.round);
        s.totalWeight = tw;
        s.totalPaid = m.totalPaid();
        s.totalWon = m.totalWon();
        if (who != address(0)) {
            s.balance = imd.balanceOf(who);
            s.allowance = imd.allowance(who, address(m));
            s.inventory = ledger.balanceOf(who);
        }
        uint256[] memory sorted = ids;
        Arrays.sort(sorted);
        for (uint256 i; i < sorted.length; ++i) {
            if (i != 0 && sorted[i] == sorted[i - 1]) continue;
            s.earned += m.earned(sorted[i]);
        }
    }

    function roundInfo(uint256 round) public view returns (RoundInfo memory r) {
        (
            uint40 begin,
            uint40 deadline,
            uint40 ended,
            uint32 mints,
            uint32 placed,
            uint32 open,
            int32 minX,
            int32 minY,
            int32 maxX,
            int32 maxY,,
            uint256 pot,,
            uint256 prize
        ) = machine.rounds(round);
        r = RoundInfo(begin, deadline, ended, mints, placed, open, minX, minY, maxX, maxY, pot, prize);
    }

    /// @notice The archive: rounds [from, from + n).
    function archive(uint256 from, uint256 n) external view returns (RoundInfo[] memory out) {
        uint256 last = machine.round();
        if (from == 0) from = 1;
        uint256 end = _rangeEnd(from, n, last + 1);
        out = new RoundInfo[](end > from ? end - from : 0);
        for (uint256 i; i < out.length; ++i) {
            out[i] = roundInfo(from + i);
        }
    }

    /// @notice Parts placed in machine `round`, in placement order from the `from`-th (1-based), two words each:
    ///         word 0 = placer | design << 160 | rot << 176 | place << 184
    ///         word 1 = id | uint32(x) << 64 | uint32(y) << 96
    function board(uint256 round, uint256 from, uint256 n) external view returns (uint256[] memory out) {
        (,,,, uint32 placed,,,,,,,,,) = machine.rounds(round);
        if (from == 0) from = 1;
        uint256 end = _rangeEnd(from, n, uint256(placed) + 1);
        out = new uint256[](end > from ? 2 * (end - from) : 0);
        for (uint256 k = from; k < end; ++k) {
            uint256 id = machine.order(round, k);
            (uint16 design, uint8 rot, uint8 place,, int32 x, int32 y,,) = machine.parts(id);
            uint256 j = 2 * (k - from);
            out[j] = uint256(uint160(machine.placerOf(id))) | (uint256(design) << 160) | (uint256(rot) << 176)
                | (uint256(place) << 184);
            out[j + 1] = id | (uint256(uint32(x)) << 64) | (uint256(uint32(y)) << 96);
        }
    }

    /// @notice `who`'s inventory parts among ids [from, from + n): ids, catalog designs, seats and the plug-pay each
    ///         carries.
    function inventory(address who, uint256 from, uint256 n)
        external
        view
        returns (uint256[] memory ids, uint16[] memory designs, uint24[] memory seatsPlus1, uint256[] memory plugs)
    {
        uint256 end = _end(from, n);
        ids = new uint256[](end > from ? end - from : 0);
        designs = new uint16[](ids.length);
        seatsPlus1 = new uint24[](ids.length);
        plugs = new uint256[](ids.length);
        uint256 k;
        for (uint256 id = from; id < end; ++id) {
            try ledger.ownerOf(id) returns (address o) {
                if (o != who) continue;
            } catch {
                continue;
            }
            (uint16 design,,,,,, uint24 seatPlus1, uint112 plug) = machine.parts(id);
            (ids[k], designs[k], seatsPlus1[k], plugs[k]) = (id, design, seatPlus1, plug);
            ++k;
        }
        assembly ("memory-safe") {
            mstore(ids, k)
            mstore(designs, k)
            mstore(seatsPlus1, k)
            mstore(plugs, k)
        }
    }

    /// @notice `who`'s unrevealed mints among ids [from, from + n) and their drand rounds. Enough to predict every
    ///         reveal.
    function pendingOf(address who, uint256 from, uint256 n)
        external
        view
        returns (uint256[] memory ids, uint64[] memory rounds)
    {
        uint256 end = _end(from, n);
        ids = new uint256[](end > from ? end - from : 0);
        rounds = new uint64[](ids.length);
        uint256 k;
        for (uint256 id = from; id < end; ++id) {
            (address owner, uint48 dr) = machine.pending(id);
            if (owner != who || who == address(0)) continue;
            (ids[k], rounds[k]) = (id, dr);
            ++k;
        }
        assembly ("memory-safe") {
            mstore(ids, k)
            mstore(rounds, k)
        }
    }

    /// @notice Distinct parts `who` placed among `ids` that have something to claim, in ascending id order, and
    ///         the total that claiming them pays.
    function claimable(address who, uint256[] calldata ids)
        external
        view
        returns (uint256[] memory out, uint256 total)
    {
        out = new uint256[](ids.length);
        uint256[] memory sorted = ids;
        Arrays.sort(sorted);
        uint256 k;
        for (uint256 i; i < sorted.length; ++i) {
            if (i != 0 && sorted[i] == sorted[i - 1]) continue;
            if (machine.placerOf(sorted[i]) != who) continue;
            uint256 e = machine.earned(sorted[i]);
            if (e == 0) continue;
            out[k++] = sorted[i];
            total += e;
        }
        assembly ("memory-safe") {
            mstore(out, k)
        }
    }

    function _end(uint256 from, uint256 n) internal view returns (uint256) {
        return _rangeEnd(from, n, machine.nextId());
    }

    function _rangeEnd(uint256 from, uint256 n, uint256 limit) private pure returns (uint256) {
        if (from >= limit) return limit;
        return n < limit - from ? from + n : limit;
    }
}
