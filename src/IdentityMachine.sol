// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {IBeacon} from "./DrandBeacon.sol";
import {Shapes} from "./Shapes.sol";
import {Catalog} from "./art/Catalog.sol";
import {Parts} from "./Parts.sol";

/// @notice The inventory ledger (Parts.sol): this machine issues items on resolution and consumes them on placement.
interface IParts {
    function ownerOf(uint256 id) external view returns (address);
    function mint(address to, uint256 id) external;
    function burn(uint256 id) external;
}

/// @title Identity Machine
/// @notice EXPERIMENTAL. A new machine every round, built by everyone, paid in IMD. No owner, no admin.
///
///   MINT   drand picks your part (rarity, then shape: Shapes.rollDrop). Each round starts at `basePrice` and
///          follows a smooth quadratic price curve. A part is a non-transferable inventory item: keep it for a later
///          round or place it.
///   PLUG   A part must plug at least one socket into the running machine (it grows from a 3×3 core with twelve
///          sockets) and every edge it touches must match: socket to socket, blank to blank. Placing burns the
///          inventory item; its earnings go to whoever placed it.
///   EARN   Half of what a part cost is paid, when it is placed, to the sockets it plugs into (split equally; the
///          core's sockets pay the pot). Every placed part also shares 26% of every later mint of its round by
///          rarity weight. A machine's parts stop earning when its round ends; what they earned stays claimable.
///   CLOCK  A round starts with 24 hours. Each placement adds 30 seconds (never more than 24 hours on the clock).
///   END    A round ends when the clock runs out. Each build must leave an outward boundary socket.
///          The last ten parts placed share 70% of the pot (30/20/13/10/8/6/5/4/2/2%). The rest of the pot,
///          including the share of any place left empty, starts the next machine's pot. The reserve matches each
///          mint's pot money while it lasts.
///
///   Each mint: 50% plug-pay, 26% every placed part, 15% round pot (matched by the reserve while it lasts), 5% reserve,
///              2% burned, 2% developer
contract IdentityMachine {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    struct Part {
        uint16 design; // the catalog part (Catalog)
        uint8 rot;
        uint8 place; // its prize place, 1 .. 10, when its round ended (0 = none)
        uint32 machine; // the round it was placed in (0 = not placed)
        int32 x;
        int32 y;
        uint24 seatPlus1; // Agent Cores: uint16 seat id + 1, including seat 65535
        uint112 plug; // the plug-pay it carries until it is placed
    }

    struct Pending {
        address owner;
        uint48 drandRound;
    }

    struct Round {
        uint40 begin;
        uint40 deadline;
        uint40 ended; // 0 while running
        uint32 minted; // mints in this round
        uint32 placed; // parts placed in this machine
        uint32 open; // open sockets
        int32 minX; // the machine's bounding box, core included
        int32 minY;
        int32 maxX;
        int32 maxY;
        uint128 totalWeight;
        uint256 pot;
        uint256 perWeight; // accumulated IMD per unit of weight, ×1e18
        uint256 prize; // paid to the ten places when it ended
    }

    /// @notice One placement for `build`: a revealed part id (yours), its rotation and position.
    struct Spot {
        uint256 id;
        uint8 rot;
        int32 x;
        int32 y;
    }

    /// @notice A real outward socket on the final machine's bounding box, supplied automatically by clients.
    struct GrowthExit {
        int32 x;
        int32 y;
        uint8 direction;
    }

    struct Proof {
        uint64 drandRound;
        bytes sig;
    }

    uint256 public constant BPS = 10_000;
    uint256 public constant PLUG = 5000;
    uint256 public constant GLOBAL = 2600;
    uint256 public constant POT = 1500;
    uint256 public constant RESERVE = 500; // funds the reserve, which matches later pot money
    uint256 public constant BURN = 200;
    uint256 public constant DEV = 200;
    uint256 public constant REFERRAL = 300; // from GLOBAL, only on a referred paid mint
    uint256 public constant WIN = 7000; // of the pot, to the ten places; the rest starts the next pot
    bytes20 internal constant PLACES = hex"0bb807d0051403e80320025801f4019000c800c8";

    uint256 public constant PRICE_SCALE = 1500; // price = basePrice * (1 + round mints / PRICE_SCALE)^2
    uint256 public constant CLOCK_ADD = 30 seconds;
    uint256 public constant CLOCK_MAX = 24 hours;
    uint256 public constant MAX_BATCH = 200;
    uint256 public constant MAX_BUILD = 50; // installed parts per build; mint/reveal batches are independent
    uint256 public constant DRAND_MARGIN = 3; // drand rounds (9-12 s) between a mint's block time and its reveal

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    int32 public constant BOUND = 100_000;
    uint256 internal constant MAG = 1e18;

    IERC20 public immutable imd;
    IBeacon public immutable beacon;
    IParts public immutable inventory;
    address public immutable dev;
    bytes32 public immutable seatRoot;
    uint256 public immutable basePrice; // IMD for the first mint of every round
    uint256 public immutable start; // when minting opens (deploy time + delay); round 1's clock starts here

    uint256 public round = 1; // the running machine
    mapping(uint256 => Round) public rounds;
    mapping(uint256 => mapping(uint256 => uint256)) public order; // round → k (1 .. placed) → the k-th part placed
    uint256 public reserve;

    mapping(uint256 => Part) public parts; // ids are shared by mints and parts: a mint reveals the part with its id
    mapping(uint256 => Pending) public pending;
    uint256 public nextId = 1;
    uint256 public minted; // all rounds

    mapping(uint256 => uint256) internal cells; // (round, x, y) → (partId + 1) << 8 | sockets  (0 = empty)

    mapping(uint256 => address) public placerOf;
    mapping(uint256 => uint256) internal debt;
    mapping(uint256 => uint256) public credit; // plug-pay and prizes received, not yet claimed

    mapping(uint16 => bool) public seatClaimed;
    uint256 public devBalance;
    mapping(address => uint256) public referralBalance; // referral credits, independent of parts and rounds
    uint256 public totalPaid; // to parts, all time (shared + plug-pay)
    uint256 public totalWon; // to the ten places, all time

    event Minted(uint256 indexed id, address indexed owner, uint256 indexed round, uint256 price, uint64 drandRound);
    event Revealed(uint256 indexed id, uint16 design, uint8 tier);
    event CoreClaimed(uint256 indexed id, uint16 indexed seat, address indexed owner);
    event Placed(uint256 indexed id, uint256 indexed round, address indexed placer, uint8 rot, int32 x, int32 y);
    event Plugged(uint256 indexed id, uint256 indexed into, uint256 amount); // into = 0: the core (the pot)
    event Claimed(address indexed who, uint256 amount);
    event ReferralPaid(address indexed beneficiary, address indexed recipient, uint256 indexed firstId, uint256 amount);
    event ReferralClaimed(address indexed beneficiary, uint256 amount);
    event Sponsored(address indexed who, uint256 indexed round, uint256 amount);
    event Funded(address indexed who, uint256 amount, bool reserve);
    event Prize(uint256 indexed round, uint256 indexed id, address indexed placer, uint8 place, uint256 amount);
    event RoundEnded(uint256 indexed round, uint256 pot, uint256 prize, uint256 carried);

    error NotOwner();
    error Occupied();
    error Mismatch();
    error NotPlugged();
    error OutOfBounds();
    error BadRot();
    error TooExpensive();
    error BadBatch();
    error NotReady();
    error BadProof();
    error SeatClaimed();
    error RoundRunning();
    error RoundOver();
    error NotStarted();
    error BadRecipient();
    error BadBuildSize();
    error NoGrowthExit();
    error BadDelay();
    error BadConfig();
    error NothingPlaced();

    constructor(
        IERC20 imd_,
        IBeacon beacon_,
        address dev_,
        bytes32 seatRoot_,
        uint256 basePrice_,
        uint256 delay_ // seconds from deployment until minting opens: the launch countdown
    ) {
        if (delay_ > 30 days) revert BadDelay();
        if (dev_ == address(0) || basePrice_ == 0) revert BadConfig();
        imd = imd_;
        beacon = beacon_;
        inventory = IParts(address(new Parts(address(this)))); // created here, so only this machine can issue items
        dev = dev_;
        seatRoot = seatRoot_;
        basePrice = basePrice_;
        start = block.timestamp + delay_;
        _open(1, start);
    }

    // ================================================================== price

    /// @notice Price of mint number `k`: basePrice * (1 + k / PRICE_SCALE)^2, rounded down in wei.
    function priceAt(uint256 k) public view returns (uint256) {
        uint256 scaled = PRICE_SCALE + k;
        return (basePrice * scaled * scaled) / (PRICE_SCALE * PRICE_SCALE);
    }

    /// @notice Price of the next mint (a new round starts over if the clock has run out).
    function price() external view returns (uint256) {
        return priceAt(_live() ? rounds[round].minted : 0);
    }

    /// @notice Total cost of the next `n` mints.
    function quote(uint256 n) external view returns (uint256 total) {
        uint256 k = _live() ? rounds[round].minted : 0;
        for (uint256 i; i < n; ++i) {
            total += priceAt(k + i);
        }
    }

    // ================================================================== rounds

    /// @notice Seconds left on the running machine's clock (0 = it is over; the next mint or `endRound` ends it).
    function timeLeft() external view returns (uint256) {
        uint256 d = rounds[round].deadline;
        return block.timestamp >= d ? 0 : d - block.timestamp;
    }

    /// @notice End a round whose clock has run out. Anyone may call; the next mint does it too.
    function endRound() public {
        if (_live()) revert RoundRunning();
        _endRound();
    }

    /// @notice Add IMD to the reserve, which matches the pot money of later mints. Anyone.
    function fundReserve(uint256 amount) external {
        imd.safeTransferFrom(msg.sender, address(this), amount);
        reserve += amount;
        emit Funded(msg.sender, amount, true);
    }

    /// @notice Add IMD to the running machine's pot, e.g. to launch a round with a prize. Anyone. (If its clock has
    ///         run out, it goes to the reserve.)
    function fundPot(uint256 amount) external {
        imd.safeTransferFrom(msg.sender, address(this), amount);
        bool live = _live();
        if (live) rounds[round].pot += amount;
        else reserve += amount;
        emit Funded(msg.sender, amount, !live);
    }

    // ================================================================== mint

    /// @notice Mint `n` parts (at most 200). Each is revealed by a drand round 9 to 12 seconds later.
    function mint(uint256 n, uint256 maxTotal) external returns (uint256 firstId, uint256 total) {
        return _mint(msg.sender, n, maxTotal, address(0));
    }

    /// @notice Same price and parts as `mint`; a referrer earns 3% from shared income. Self-referrals are allowed.
    function mintWithReferral(uint256 n, uint256 maxTotal, address referrer)
        external
        returns (uint256 firstId, uint256 total)
    {
        return _mint(msg.sender, n, maxTotal, referrer);
    }

    /// @notice The caller pays; the parts belong to `recipient` (e.g. an ETH checkout).
    function mintFor(address recipient, uint256 n, uint256 maxTotal) external returns (uint256 firstId, uint256 total) {
        if (recipient == address(0)) revert BadRecipient();
        return _mint(recipient, n, maxTotal, address(0));
    }

    /// @notice Referral-aware checkout: caller pays, recipient owns the parts.
    function mintForWithReferral(address recipient, uint256 n, uint256 maxTotal, address referrer)
        external
        returns (uint256 firstId, uint256 total)
    {
        if (recipient == address(0)) revert BadRecipient();
        return _mint(recipient, n, maxTotal, referrer);
    }

    function _mint(address recipient, uint256 n, uint256 maxTotal, address referrer)
        private
        returns (uint256 firstId, uint256 total)
    {
        if (block.timestamp < start) revert NotStarted();
        if (n == 0 || n > MAX_BATCH) revert BadBatch();
        if (!_live()) _endRound();
        uint256 r = round;
        Round storage R = rounds[r];
        uint48 dr = uint48(beacon.roundAt(block.timestamp) + DRAND_MARGIN);
        uint256 k = R.minted;
        firstId = nextId;
        uint256 plugs;
        for (uint256 i; i < n; ++i) {
            uint256 p = priceAt(k + i);
            uint256 plug = (p * PLUG) / BPS;
            plugs += plug;
            total += p;
            uint256 id = firstId + i;
            pending[id] = Pending(recipient, dr);
            parts[id].plug = plug.toUint112();
            emit Minted(id, recipient, r, p, dr);
        }
        if (total > maxTotal) revert TooExpensive();

        // effects before the transfer in (checks-effects-interactions)
        nextId = firstId + n;
        minted += n;
        R.minted = uint32(k + n);
        imd.safeTransferFrom(msg.sender, address(this), total);

        uint256 toReserve = (total * RESERVE) / BPS;
        uint256 burn = (total * BURN) / BPS;
        uint256 devCut = (total * DEV) / BPS;
        uint256 toPot = (total * POT) / BPS;
        uint256 matched = toPot < reserve ? toPot : reserve;
        reserve -= matched;
        devBalance += devCut;
        R.pot += toPot + matched;
        uint256 reward;
        if (referrer != address(0) && referrer != address(this) && referrer != DEAD) {
            reward = (total * REFERRAL) / BPS;
            referralBalance[referrer] += reward;
            emit ReferralPaid(referrer, recipient, firstId, reward);
        }
        // shared income (26%, or 23% with a referral) takes the rounding dust
        _distribute(R, total - plugs - toReserve - burn - devCut - toPot - reward);
        reserve += toReserve;
        imd.safeTransfer(DEAD, burn);
    }

    /// @notice Reveal mints whose drand round is public. Anyone may call; parts go to their minters. Mints already
    ///         revealed are skipped.
    function reveal(uint256[] calldata ids) public {
        for (uint256 i; i < ids.length; ++i) {
            if (pending[ids[i]].owner != address(0)) _reveal(ids[i]);
        }
    }

    function _reveal(uint256 id) internal {
        Pending memory pm = pending[id];
        bytes32 r = beacon.randomness(pm.drandRound);
        if (r == 0) revert NotReady();
        delete pending[id];
        uint256 x = uint256(keccak256(abi.encode(r, id)));
        uint8 tier = rollTier(x);
        uint16 d = Catalog.partFor(tier, Shapes.rollDrop(tier, x >> 16), x >> 32);
        parts[id].design = d;
        inventory.mint(pm.owner, id);
        emit Revealed(id, d, tier);
    }

    /// @notice identity.md seat holders (snapshot) claim one free Agent Core each. It carries no plug-pay.
    function claimAgentCore(uint16 seat, bytes32[] calldata proof) external returns (uint256 id) {
        if (block.timestamp < start) revert NotStarted();
        if (seatClaimed[seat]) revert SeatClaimed();
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(seat, msg.sender))));
        if (!MerkleProof.verify(proof, seatRoot, leaf)) revert BadProof();
        seatClaimed[seat] = true;
        id = nextId++;
        parts[id].design = Catalog.AGENT_CORE;
        parts[id].seatPlus1 = uint24(seat) + 1;
        inventory.mint(msg.sender, id);
        emit CoreClaimed(id, seat, msg.sender);
    }

    /// @notice Rarity: 70% common, 22% uncommon, 7% rare, 1% legendary.
    function rollTier(uint256 x) public pure returns (uint8) {
        uint256 roll = x % 10_000;
        return roll < 7000 ? 0 : roll < 9200 ? 1 : roll < 9900 ? 2 : 3;
    }

    /// @notice Share weight by rarity: common 1, uncommon 2, rare 5, legendary 20, Agent Core 1.
    function weightOf(uint16 design) public pure returns (uint256) {
        uint8 tier = Catalog.tierOf(design);
        return tier == 3 ? 20 : tier == 2 ? 5 : tier == 1 ? 2 : 1;
    }

    // ================================================================== plug in

    /// @notice Reveal mints and plug parts into machine `r` (the running one) in one transaction. `proofs` are drand
    ///         signatures for rounds not proven yet (may be empty); `ids` are mints to reveal first (already revealed
    ///         ones are skipped). Spots are placed in order. The final state must leave the supplied outward socket;
    ///         otherwise the entire transaction reverts, including reveals, consumption, payments and clock changes.
    function build(
        uint256 r,
        Proof[] calldata proofs,
        uint256[] calldata ids,
        Spot[] calldata spots,
        GrowthExit calldata exit
    ) external {
        if (block.timestamp < start) revert NotStarted();
        if (r != round || !_live()) revert RoundOver();
        if (spots.length > MAX_BUILD) revert BadBuildSize();
        for (uint256 i; i < proofs.length; ++i) {
            beacon.prove(proofs[i].drandRound, proofs[i].sig);
        }
        reveal(ids);
        for (uint256 i; i < spots.length; ++i) {
            _place(r, spots[i]);
        }
        _checkGrowth(r, exit);
    }

    /// @dev One cell lookup and the existing bounds suffice: beyond an outward bounding-box edge is empty space.
    ///      Single-bit directions and room for the next cell are required. No board scan or new storage.
    function _checkGrowth(uint256 r, GrowthExit calldata exit) internal view {
        Round storage R = rounds[r];
        bool outer = (exit.direction == Shapes.N && exit.y == R.minY && exit.y > -BOUND)
            || (exit.direction == Shapes.E && exit.x == R.maxX && exit.x < BOUND)
            || (exit.direction == Shapes.S && exit.y == R.maxY && exit.y < BOUND)
            || (exit.direction == Shapes.W && exit.x == R.minX && exit.x > -BOUND);
        if (!outer || (_cell(r, exit.x, exit.y) & exit.direction) == 0) revert NoGrowthExit();
    }

    function _place(uint256 r, Spot calldata s) internal {
        uint256 id = s.id;
        if (inventory.ownerOf(id) != msg.sender) revert NotOwner();
        Part storage p = parts[id];
        Round storage R = rounds[r];
        (uint256 links, uint256[8] memory into, uint256 sockets) = _fit(r, R, id, p.design, s);
        p.machine = uint32(r);
        p.rot = s.rot;
        p.x = s.x;
        p.y = s.y;
        inventory.burn(id);
        placerOf[id] = msg.sender;
        emit Placed(id, r, msg.sender, s.rot, s.x, s.y);

        // plug-pay: split equally between the sockets it plugs into; the core's sockets (and the dust) pay the pot
        uint256 plug = p.plug;
        if (plug > 0) {
            p.plug = 0;
            uint256 share = plug / links;
            for (uint256 i; i < links; ++i) {
                if (into[i] == 0) {
                    R.pot += share;
                } else {
                    credit[into[i]] += share;
                    totalPaid += share;
                }
                emit Plugged(id, into[i], share);
            }
            R.pot += plug - share * links;
        }

        uint256 w = weightOf(p.design);
        debt[id] = w * R.perWeight;
        R.totalWeight += uint128(w);
        uint256 k = R.placed + 1;
        R.placed = uint32(k);
        order[r][k] = id;
        R.open = uint32(R.open + sockets - 2 * links);
        uint256 d = R.deadline + CLOCK_ADD;
        uint256 cap = block.timestamp + CLOCK_MAX;
        R.deadline = uint40(d < cap ? d : cap);
    }

    /// @dev Checks a placement, writes its cells and the bounding box. Returns the parts it plugs into.
    function _fit(uint256 r, Round storage R, uint256 id, uint16 design, Spot calldata s)
        internal
        returns (uint256 links, uint256[8] memory into, uint256 sockets)
    {
        if (s.rot > 3) revert BadRot();
        (uint8 n, int32[9] memory cx, int32[9] memory cy, uint8[9] memory m) =
            Shapes.footprint(Catalog.tmplOf(design), s.rot, s.x, s.y);
        (links, into, sockets) = _wires(r, n, cx, cy, m);
        (int32 x0, int32 y0, int32 x1, int32 y1) = (R.minX, R.minY, R.maxX, R.maxY);
        for (uint256 i; i < n; ++i) {
            (int32 x, int32 y) = (cx[i], cy[i]);
            cells[_key(r, x, y)] = ((id + 1) << 8) | m[i];
            if (x < x0) x0 = x;
            if (x > x1) x1 = x;
            if (y < y0) y0 = y;
            if (y > y1) y1 = y;
        }
        (R.minX, R.minY, R.maxX, R.maxY) = (x0, y0, x1, y1);
    }

    /// @dev The wiring rules for cells (cx, cy) with sockets m in machine r: free cells, every touching edge matches,
    ///      at least one socket plugs in. Returns what it plugs into and the part's own socket count.
    function _wires(uint256 r, uint8 n, int32[9] memory cx, int32[9] memory cy, uint8[9] memory m)
        internal
        view
        returns (uint256 links, uint256[8] memory into, uint256 sockets)
    {
        for (uint256 i; i < n; ++i) {
            if (cx[i] > BOUND || cx[i] < -BOUND || cy[i] > BOUND || cy[i] < -BOUND) revert OutOfBounds();
            if (_cell(r, cx[i], cy[i]) != 0) revert Occupied();
        }
        for (uint256 i; i < n; ++i) {
            for (uint8 d = 1; d <= 8; d <<= 1) {
                (int32 nx, int32 ny) = _step(cx[i], cy[i], d);
                if (_inside(n, cx, cy, nx, ny)) continue; // an edge inside the part
                bool mine = m[i] & d != 0;
                if (mine) ++sockets;
                uint256 c = _cell(r, nx, ny);
                if (c == 0) continue;
                if (mine != (uint8(c) & _opp(d) != 0)) revert Mismatch();
                if (mine) into[links++] = (c >> 8) - 1; // capacity covers the catalogue's maximum external socket count
            }
        }
        if (links == 0) revert NotPlugged();
    }

    /// @notice Would catalog part `design` fit the running machine at (rot, x, y)? Reverts with the reason if not,
    ///         else returns the parts its plug-pay would go to (0 = the core). For agents and UIs. Once the clock
    ///         has run out nothing more can be placed on this machine, so it reverts RoundOver, as build does.
    function check(uint16 design, uint8 rot, int32 x, int32 y) external view returns (uint256[] memory payees) {
        if (!_live()) revert RoundOver();
        if (rot > 3) revert BadRot();
        (uint8 n, int32[9] memory cx, int32[9] memory cy, uint8[9] memory m) =
            Shapes.footprint(Catalog.tmplOf(design), rot, x, y);
        (uint256 links, uint256[8] memory into,) = _wires(round, n, cx, cy, m);
        payees = new uint256[](links);
        for (uint256 i; i < links; ++i) {
            payees[i] = into[i];
        }
    }

    // ================================================================== earn

    /// @notice IMD this placed part has earned and not yet claimed: plug-pay and prizes received plus its share of
    ///         its machine's later mints.
    function earned(uint256 id) public view returns (uint256) {
        uint256 r = parts[id].machine;
        if (r == 0) return 0;
        return credit[id] + (weightOf(parts[id].design) * rounds[r].perWeight - debt[id]) / MAG;
    }

    /// @notice Claim what parts you placed have earned.
    function claim(uint256[] calldata ids) external returns (uint256 amount) {
        for (uint256 i; i < ids.length; ++i) {
            uint256 id = ids[i];
            if (placerOf[id] != msg.sender) revert NotOwner();
            uint256 shared = (weightOf(parts[id].design) * rounds[parts[id].machine].perWeight - debt[id]) / MAG;
            debt[id] += shared * MAG;
            amount += shared + credit[id];
            credit[id] = 0;
        }
        if (amount > 0) {
            imd.safeTransfer(msg.sender, amount);
            emit Claimed(msg.sender, amount);
        }
    }

    /// @notice Anyone can push the developer's 2% to the developer.
    function payDev() external {
        uint256 a = devBalance;
        devBalance = 0;
        imd.safeTransfer(dev, a);
    }

    /// @notice Withdraw referral rewards. Remains claimable across round ends.
    function claimReferral() external returns (uint256 amount) {
        amount = referralBalance[msg.sender];
        referralBalance[msg.sender] = 0;
        if (amount > 0) {
            imd.safeTransfer(msg.sender, amount);
            emit ReferralClaimed(msg.sender, amount);
        }
    }

    /// @notice Anyone can sponsor the builders: IMD paid straight to every part of the running machine, by weight.
    ///         Reverts while the running machine has no parts placed (fundPot adds to its pot instead).
    function sponsor(uint256 amount) external {
        if (!_live()) revert RoundOver();
        if (rounds[round].totalWeight == 0) revert NothingPlaced();
        imd.safeTransferFrom(msg.sender, address(this), amount);
        _distribute(rounds[round], amount);
        emit Sponsored(msg.sender, round, amount);
    }

    // ================================================================== prizes

    /// @notice The prize order of machine `r`: its last ten parts placed, the most recent first. (For a finished
    ///         round: who was paid.)
    function leaders(uint256 r) external view returns (uint256[] memory ids) {
        uint256 placed = rounds[r].placed;
        ids = new uint256[](placed < 10 ? placed : 10);
        for (uint256 i; i < ids.length; ++i) {
            ids[i] = order[r][placed - i];
        }
    }

    // ================================================================== views

    function cellAt(uint256 r, int32 x, int32 y) external view returns (bool occupied, uint256 partId, uint8 sockets) {
        uint256 c = _cell(r, x, y);
        return (c != 0, c == 0 ? 0 : (c >> 8) - 1, uint8(c));
    }

    // ================================================================== internals

    function _live() internal view returns (bool) {
        return block.timestamp < rounds[round].deadline;
    }

    function _open(uint256 r, uint256 t) internal {
        Round storage R = rounds[r];
        R.begin = uint40(t);
        R.deadline = uint40(t + CLOCK_MAX);
        R.open = 12; // the 3×3 core: two sockets on each corner, one in the middle of each side
        (R.minX, R.minY, R.maxX, R.maxY) = (-1, -1, 1, 1);
    }

    /// @dev Ends the running round: the last ten parts placed share 70% of the pot, and the rest (with the share of
    ///      any place left empty) starts the next machine's pot, which opens at once. No external calls.
    function _endRound() internal {
        uint256 r = round;
        Round storage R = rounds[r];
        uint256 pot = R.pot;
        uint256 prize = (pot * WIN) / BPS;
        uint256 placed = R.placed;
        uint256 filled = placed < 10 ? placed : 10;
        uint256 paid;
        for (uint256 i; i < filled; ++i) {
            uint256 id = order[r][placed - i];
            uint256 amount = (prize * placeBps(i)) / BPS;
            credit[id] += amount;
            paid += amount;
            parts[id].place = uint8(i + 1);
            emit Prize(r, id, placerOf[id], uint8(i + 1), amount);
        }
        R.ended = R.deadline;
        R.prize = paid;
        totalWon += paid;
        emit RoundEnded(r, pot, paid, pot - paid);
        round = r + 1;
        _open(r + 1, block.timestamp);
        rounds[r + 1].pot = pot - paid;
    }

    /// @notice First to tenth place's share of the prize, in basis points: 30 / 20 / 13 / 10 / 8 / 6 / 5 / 4 / 2 / 2%.
    function placeBps(uint256 i) public pure returns (uint256) {
        return uint16(bytes2(PLACES << (i * 16)));
    }

    function _distribute(Round storage R, uint256 amount) internal {
        if (amount == 0) return;
        if (R.totalWeight == 0) {
            R.pot += amount; // nothing placed yet: the pot takes it
            return;
        }
        R.perWeight += (amount * MAG) / R.totalWeight;
        totalPaid += amount;
    }

    /// @dev The cell at (x, y) of machine r; the 3×3 core around the origin is implicit (part 0).
    function _cell(uint256 r, int32 x, int32 y) internal view returns (uint256) {
        if (x >= -1 && x <= 1 && y >= -1 && y <= 1) {
            uint256 m =
                (y == -1 ? Shapes.N : 0) | (x == 1 ? Shapes.E : 0) | (y == 1 ? Shapes.S : 0) | (x == -1 ? Shapes.W : 0);
            return (1 << 8) | m;
        }
        return cells[_key(r, x, y)];
    }

    function _inside(uint8 n, int32[9] memory cx, int32[9] memory cy, int32 x, int32 y) internal pure returns (bool) {
        for (uint256 i; i < n; ++i) {
            if (cx[i] == x && cy[i] == y) return true;
        }
        return false;
    }

    function _step(int32 x, int32 y, uint8 d) internal pure returns (int32, int32) {
        if (d == 1) return (x, y - 1);
        if (d == 2) return (x + 1, y);
        if (d == 4) return (x, y + 1);
        return (x - 1, y);
    }

    function _opp(uint8 d) internal pure returns (uint8) {
        return d == 1 ? 4 : d == 4 ? 1 : d == 2 ? 8 : 2;
    }

    function _key(uint256 r, int32 x, int32 y) internal pure returns (uint256) {
        return (r << 64) | (uint256(uint32(x)) << 32) | uint256(uint32(y));
    }
}
