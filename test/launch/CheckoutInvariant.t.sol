// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IdentityMachine} from "src/IdentityMachine.sol";
import {MachineViews} from "src/MachineViews.sol";
import {EthMinter} from "src/EthMinter.sol";
import {Parts} from "src/Parts.sol";
import {ManifestFixture} from "./ManifestFixture.sol";
import {CheckoutToken, SettlementPool} from "./SettlementModel.sol";

/// Random transactions against the production applications, with independent flow accounting.
/// Paid items stay pending: their plug-pay remains a liability even after many round ends.
/// A real snapshot core supplies a placed, earning item without forging drand randomness.
contract ManifestCheckoutHandler is Test {
    IdentityMachine public immutable machine;
    EthMinter public immutable checkout;
    MachineViews public immutable views;
    CheckoutToken public immutable token;
    SettlementPool public immutable pool;
    uint256 public immutable core;
    address[3] public actors;

    uint256 public purchases;
    uint256 public created;
    uint256 public swappedImd;
    uint256 public ethSpent;
    uint256 public funded;
    uint256 public pendingPlugs;
    uint256 public expectedBurn;
    uint256 public expectedDev;
    uint256 public devWithdrawn;
    uint256 public referralsWithdrawn;
    uint256 public earningsWithdrawn;
    uint256 public donatedEth;
    uint256 public donatedImd;
    uint256 public failures;
    mapping(address => uint256) public spentBy;
    mapping(address => uint256) public referralAccrued;

    constructor(
        IdentityMachine m,
        EthMinter c,
        MachineViews v,
        CheckoutToken t,
        SettlementPool p,
        address[3] memory a,
        uint256 coreId
    ) {
        (machine, checkout, views, token, pool, actors, core) = (m, c, v, t, p, a, coreId);
    }

    function _referrer(uint256 seed) internal view returns (address) {
        uint256 k = seed % 7;
        if (k == 0) return address(0);
        if (k <= 3) return actors[k - 1];
        if (k == 4) return address(checkout);
        if (k == 5) return address(machine);
        return machine.DEAD();
    }

    function buy(uint256 who, uint256 count, uint256 extra, uint256 referral) public {
        address actor = actors[who % 3];
        uint256 n = bound(count, 1, 8);
        uint256 refund = bound(extra, 0, 1 ether);
        address referrer = _referrer(referral);
        (uint256 total, uint256 cost) = checkout.quote(n);
        uint256 balance = actor.balance;
        uint256 next = machine.nextId();
        uint256 first;
        uint256 paid;
        vm.prank(actor);
        if (referrer == address(0)) {
            (first, paid) = checkout.mint{value: cost + refund}(n, total, vm.getBlockTimestamp());
        } else {
            (first, paid) = checkout.mintWithReferral{value: cost + refund}(n, total, vm.getBlockTimestamp(), referrer);
        }
        assertEq(first, next, "no skipped or reused id");
        assertEq(paid, cost, "quote equals executed exact-output input");
        assertEq(balance - actor.balance, paid, "unused ETH refunded to payer");
        for (uint256 i; i < n; ++i) {
            (address owner, uint48 dr) = machine.pending(first + i);
            assertEq(owner, actor, "checkout cannot retain another user's items");
            uint256 publication = machine.beacon().timeOf(dr);
            assertGe(publication, vm.getBlockTimestamp() + 9);
            assertLe(publication, vm.getBlockTimestamp() + 11);
            (,,,,,,, uint112 plug) = machine.parts(first + i);
            pendingPlugs += plug;
        }
        ++purchases;
        created += n;
        swappedImd += total;
        ethSpent += paid;
        spentBy[actor] += paid;
        expectedBurn += total / 50;
        expectedDev += total / 50;
        for (uint256 i; i < actors.length; ++i) {
            if (referrer == actors[i]) referralAccrued[referrer] += total * 3 / 100;
        }
    }

    function changeRate(uint256 rate) external {
        pool.setRate(bound(rate, 1, 0.1 ether));
    }

    function fund(uint256 who, uint256 amount, uint256 kind) external {
        address actor = actors[who % 3];
        amount = bound(amount, 0, 10 ether);
        uint256 beforeBalance = token.balanceOf(actor);
        uint256 mode = kind % 3;
        MachineViews.RoundInfo memory info = views.roundInfo(machine.round());
        if (mode == 2 && (info.placed == 0 || vm.getBlockTimestamp() >= info.deadline)) {
            vm.expectRevert(
                info.placed == 0 && vm.getBlockTimestamp() < info.deadline
                    ? IdentityMachine.NothingPlaced.selector
                    : IdentityMachine.RoundOver.selector
            );
            vm.prank(actor);
            machine.sponsor(amount);
            assertEq(token.balanceOf(actor), beforeBalance);
            return;
        }
        vm.prank(actor);
        if (mode == 0) machine.fundReserve(amount);
        else if (mode == 1) machine.fundPot(amount);
        else machine.sponsor(amount);
        assertEq(beforeBalance - token.balanceOf(actor), amount);
        funded += amount;
    }

    function withdraw(uint256 who) public {
        address actor = actors[who % 3];
        uint256 beforeBalance = token.balanceOf(actor);
        uint256 referral = machine.referralBalance(actor);
        vm.prank(actor);
        uint256 paid = machine.claimReferral();
        assertEq(paid, referral);
        assertEq(token.balanceOf(actor) - beforeBalance, referral);
        referralsWithdrawn += paid;
        // Repeat withdrawal must be harmless and must not spend another actor's credit.
        vm.prank(actor);
        assertEq(machine.claimReferral(), 0);
        if (actor == actors[2]) {
            uint256 earned = machine.earned(core);
            beforeBalance = token.balanceOf(actor);
            vm.prank(actor);
            paid = machine.claim(_one(core));
            assertEq(paid, earned);
            assertEq(token.balanceOf(actor) - beforeBalance, earned);
            earningsWithdrawn += paid;
        }
        uint256 devCredit = machine.devBalance();
        uint256 devBefore = token.balanceOf(machine.dev());
        vm.prank(actor);
        machine.payDev();
        assertEq(token.balanceOf(machine.dev()) - devBefore, devCredit, "payout goes only to launch owner");
        devWithdrawn += devCredit;
    }

    function advance(uint256 secondsForward, bool endExplicitly) external {
        vm.warp(vm.getBlockTimestamp() + bound(secondsForward, 0, 2 days));
        if (endExplicitly && machine.timeLeft() == 0) {
            uint256 r = machine.round();
            machine.endRound();
            assertEq(machine.round(), r + 1);
            assertEq(views.roundInfo(r).ended, views.roundInfo(r).deadline);
        }
    }

    function donate(uint256 who, uint256 imd, uint256 eth) external {
        imd = bound(imd, 0, 1 ether);
        eth = bound(eth, 0, 1 ether);
        vm.prank(actors[who % 3]);
        token.transfer(address(checkout), imd);
        // Model forced ETH independently of user payments; never overwrite an existing balance.
        vm.deal(address(checkout), address(checkout).balance + eth);
        donatedImd += imd;
        donatedEth += eth;
    }

    /// Faults before and after settlement, including a failing burn after the machine has written mint state.
    function rejectedBuy(uint256 who, uint256 fault) external {
        address actor = actors[who % 3];
        uint256 mode = fault % 5;
        (uint256 total, uint256 cost) = checkout.quote(3);
        uint256 value = cost + 1;
        uint256 expires = vm.getBlockTimestamp();
        uint256 maxImd = total;
        bytes4 expected;
        address blocked;
        if (mode == 0) {
            value = cost - 1;
            expected = EthMinter.NotEnoughEth.selector;
        } else if (mode == 1) {
            --expires;
            expected = EthMinter.QuoteExpired.selector;
        } else if (mode == 2) {
            --maxImd;
            expected = EthMinter.TooExpensive.selector;
        } else {
            blocked = mode == 3 ? address(checkout) : machine.DEAD();
            token.setBlocked(blocked, true);
            expected = CheckoutToken.Blocked.selector;
        }
        bytes32 beforeState = fingerprint();
        vm.prank(actor);
        (bool ok, bytes memory reason) = address(checkout).call{value: value}(
            abi.encodeCall(EthMinter.mintWithReferral, (3, maxImd, expires, actors[1]))
        );
        assertFalse(ok, "invalid purchase succeeded");
        assertEq(bytes4(reason), expected, "failure occurred at the intended boundary");
        assertEq(fingerprint(), beforeState, "failed purchase left balances, credit, or mint state behind");
        if (blocked != address(0)) token.setBlocked(blocked, false);
        ++failures;
    }

    function rejectedPayout() external {
        // Always test a real unpaid liability; zero-value transfer policy is a token implementation detail.
        if (machine.devBalance() == 0) buy(0, 1, 0, 0);
        address dev = machine.dev();
        token.setBlocked(dev, true);
        bytes32 beforeState = fingerprint();
        vm.expectRevert(CheckoutToken.Blocked.selector);
        machine.payDev();
        assertEq(fingerprint(), beforeState, "unpaid developer credit was lost");
        token.setBlocked(dev, false);
        ++failures;
    }

    function fingerprint() public view returns (bytes32 h) {
        uint256 r = machine.round();
        h = keccak256(
            abi.encode(
                views.status(address(0), _one(core)),
                views.roundInfo(r),
                views.roundInfo(r + 1),
                token.balanceOf(address(machine)),
                token.balanceOf(address(checkout)),
                token.balanceOf(address(pool)),
                token.balanceOf(machine.DEAD()),
                token.balanceOf(machine.dev()),
                address(checkout).balance,
                address(pool).balance,
                token.allowance(address(checkout), address(machine)),
                pool.swaps(),
                pool.ethSettled(),
                pool.tokensTaken(),
                pool.locker(),
                pool.ethDebt(),
                pool.tokenCredit(),
                machine.devBalance(),
                machine.credit(core)
            )
        );
        for (uint256 i; i < actors.length; ++i) {
            h = keccak256(
                abi.encode(h, actors[i].balance, token.balanceOf(actors[i]), machine.referralBalance(actors[i]))
            );
        }
        for (uint256 id = machine.nextId(); id < machine.nextId() + 3; ++id) {
            (address owner, uint48 dr) = machine.pending(id);
            (,,,,,,, uint112 plug) = machine.parts(id);
            h = keccak256(abi.encode(h, owner, dr, plug));
        }
    }

    function liabilities() external view returns (uint256 owed) {
        owed = machine.reserve() + machine.devBalance() + views.roundInfo(machine.round()).pot + pendingPlugs
            + machine.earned(core);
        for (uint256 i; i < actors.length; ++i) {
            owed += machine.referralBalance(actors[i]);
        }
    }

    function _one(uint256 id) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = id;
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract ManifestCheckoutInvariantTest is ManifestFixture {
    ManifestCheckoutHandler internal handler;
    address[3] internal actors;
    uint256 internal core;

    function setUp() public {
        _deployManifest(1_800_000_000);
        vm.warp(machine.start());
        actors = [makeAddr("manifest checkout buyer one"), makeAddr("manifest checkout buyer two"), seatHolder];
        for (uint256 i; i < actors.length; ++i) {
            _fundActor(actors[i]);
        }
        core = _claimCore();
        _placeCore(core);
        handler = new ManifestCheckoutHandler(machine, checkout, views, token, pool, actors, core);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.buy.selector;
        selectors[1] = handler.changeRate.selector;
        selectors[2] = handler.fund.selector;
        selectors[3] = handler.withdraw.selector;
        selectors[4] = handler.advance.selector;
        selectors[5] = handler.donate.selector;
        selectors[6] = handler.rejectedBuy.selector;
        selectors[7] = handler.rejectedPayout.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        // Start with genuine accrued earnings and all three possible referral beneficiaries.
        for (uint256 i; i < actors.length; ++i) {
            handler.buy(i, 1, 1, i + 1);
        }
    }

    /// Exact here: the sole installed core has weight one, so there is no shared-income division dust.
    function invariant_machineCanCoverEveryLiability() public view {
        assertEq(token.balanceOf(address(machine)), handler.liabilities(), "IMD backing differs from all liabilities");
        assertEq(
            handler.swappedImd() + handler.funded(),
            token.balanceOf(address(machine)) + handler.expectedBurn() + handler.devWithdrawn()
                + handler.referralsWithdrawn() + handler.earningsWithdrawn()
        );
        assertEq(token.balanceOf(machine.DEAD()), handler.expectedBurn());
        assertEq(machine.devBalance() + handler.devWithdrawn(), handler.expectedDev());
        assertEq(token.balanceOf(LAUNCH_DEV), handler.devWithdrawn());
        uint256 remainingReferral;
        uint256 accruedReferral;
        for (uint256 i; i < actors.length; ++i) {
            remainingReferral += machine.referralBalance(actors[i]);
            accruedReferral += handler.referralAccrued(actors[i]);
        }
        assertEq(remainingReferral + handler.referralsWithdrawn(), accruedReferral);
    }

    function invariant_checkoutCannotRetainPaymentsOrSpendDonations() public view {
        assertEq(address(checkout).balance, handler.donatedEth());
        assertEq(token.balanceOf(address(checkout)), handler.donatedImd());
        assertEq(token.allowance(address(checkout), address(machine)), 0);
        assertEq(machine.referralBalance(address(checkout)), 0);
        assertEq(machine.referralBalance(address(machine)), 0);
        assertEq(machine.referralBalance(machine.DEAD()), 0);
        assertEq(address(pool).balance, handler.ethSpent());
        assertEq(token.balanceOf(address(pool)) + handler.swappedImd(), POOL_TOKENS);
        assertEq(pool.swaps(), handler.purchases());
        assertEq(pool.ethSettled(), handler.ethSpent());
        assertEq(pool.tokensTaken(), handler.swappedImd());
        assertEq(pool.locker(), address(0));
        assertEq(pool.ethDebt(), 0);
        assertEq(pool.tokenCredit(), 0);
        uint256 totalActorTokens;
        for (uint256 i; i < actors.length; ++i) {
            assertEq(actors[i].balance + handler.spentBy(actors[i]), ACTOR_ETH);
            totalActorTokens += token.balanceOf(actors[i]);
        }
        assertEq(
            totalActorTokens + handler.funded() + handler.donatedImd(),
            3 * ACTOR_TOKENS + handler.referralsWithdrawn() + handler.earningsWithdrawn()
        );
    }

    function invariant_onlyPaidMintsCreatePendingItems() public view {
        assertEq(machine.minted(), handler.created());
        assertEq(machine.nextId(), handler.created() + 2, "one claimed snapshot core plus paid mints");
        assertEq(inventory.totalSupply(), 0, "pending items cannot appear in inventory before proof");
        assertEq(machine.placerOf(core), seatHolder);
    }

    function afterInvariant() public {
        for (uint256 i; i < actors.length; ++i) {
            handler.withdraw(i);
        }
        invariant_machineCanCoverEveryLiability();
        invariant_checkoutCannotRetainPaymentsOrSpendDonations();
        assertEq(machine.devBalance(), 0);
        assertEq(machine.earned(core), 0);
        for (uint256 i; i < actors.length; ++i) {
            assertEq(machine.referralBalance(actors[i]), 0);
        }
    }

    /// Deterministic reachability check: every fault is exercised with existing funds, then recovery succeeds.
    function test_campaignExercisesEveryFaultAcrossRoundRollover() public {
        handler.donate(0, 1 ether, 1 ether);
        handler.fund(1, 1 ether, 2);
        handler.advance(2 days, false);
        uint256 oldRound = machine.round();
        for (uint256 i; i < 5; ++i) {
            handler.rejectedBuy(i, i);
        }
        assertEq(machine.round(), oldRound, "failed burn must also roll back tentative round end and prize");
        handler.rejectedPayout();
        handler.buy(2, 8, 1 ether, 3);
        assertEq(machine.round(), oldRound + 1);
        assertGt(machine.credit(core), 0, "successful rollover actually awarded a prize");
        assertEq(handler.failures(), 6);
        afterInvariant();
    }
}
