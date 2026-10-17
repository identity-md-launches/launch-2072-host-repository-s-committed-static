// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    EthMinter,
    IEthPoolManager,
    IEthQuoter,
    EthPoolKey,
    EthSwapParams,
    EthQuoteParams
} from "../../src/EthMinter.sol";
import {IdentityMachine} from "../../src/IdentityMachine.sol";
import {MockIMD} from "../Mocks.sol";
import {Base, G} from "../Base.sol";

interface ICheckoutCallback {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

/// Assumption stress fixture, not a v4 liquidity model. Faults test callback rollback and retry.
contract CallbackPool {
    MockIMD immutable imd;
    uint256 public rate = 0.0035 ether;
    uint256 public unlocks;
    uint256 public swaps;
    uint256 public settlements;
    uint256 public takes;
    uint8 public fault; // 1 missing callback, 2 duplicate, 3 malformed data
    address locker;

    constructor(MockIMD token) {
        imd = token;
    }

    function setFault(uint8 f) external {
        fault = f;
    }

    function setRate(uint256 r) external {
        rate = r;
    }

    function poolManager() external view returns (address) {
        return address(this);
    }

    function quoteExactOutputSingle(EthQuoteParams calldata p) external view returns (uint256, uint256) {
        return ((uint256(p.exactAmount) * rate + 1 ether - 1) / 1 ether, 50_000);
    }

    function unlock(bytes calldata data) external returns (bytes memory result) {
        require(locker == address(0), "locked");
        locker = msg.sender;
        ++unlocks;
        if (fault == 1) {
            result = abi.encode(uint256(0));
        } else {
            result = ICheckoutCallback(msg.sender).unlockCallback(fault == 3 ? bytes("") : data);
            if (fault == 2) ICheckoutCallback(msg.sender).unlockCallback(data);
        }
        locker = address(0);
    }

    function swap(EthPoolKey calldata, EthSwapParams calldata p, bytes calldata) external returns (int256) {
        require(msg.sender == locker, "not locker");
        ++swaps;
        uint256 output =
            p.amountSpecified > 0 ? uint256(p.amountSpecified) : uint256(-p.amountSpecified) * 1 ether / rate;
        uint256 spent = p.amountSpecified > 0 ? (output * rate + 1 ether - 1) / 1 ether : uint256(-p.amountSpecified);
        return (int256(-int128(int256(spent))) << 128) | int256(uint256(uint128(output)));
    }

    function settle() external payable returns (uint256) {
        require(msg.sender == locker, "not locker");
        ++settlements;
        return msg.value;
    }

    function take(address currency, address to, uint256 amount) external {
        require(msg.sender == locker && currency == address(imd), "not locker");
        ++takes;
        imd.mint(to, amount);
    }
}

contract SecurityCheckoutTest is Base {
    CallbackPool pool;
    EthMinter minter;

    function setUp() public override {
        super.setUp();
        pool = new CallbackPool(imd);
        minter = new EthMinter(m, IEthPoolManager(address(pool)), IEthQuoter(address(pool)), 10_000, 100);
        vm.deal(alice, 100 ether);
    }

    function _assertCleanFailure(uint256 aliceBefore, uint256 next, uint256 supply) internal view {
        assertEq(alice.balance, aliceBefore);
        assertEq(m.nextId(), next);
        assertEq(imd.totalSupply(), supply);
        assertEq(address(minter).balance, 0);
        assertEq(imd.balanceOf(address(minter)), 0);
        assertEq(imd.allowance(address(minter), address(m)), 0);
        assertEq(address(pool).balance, 0);
        assertEq(pool.unlocks(), 0);
        assertEq(pool.swaps(), 0);
        assertEq(pool.settlements(), 0);
        assertEq(pool.takes(), 0);
    }

    function _retry(uint256 total, uint256 cost) internal {
        vm.clearMockedCalls();
        pool.setFault(0);
        vm.prank(alice);
        minter.mint{value: cost}(1, total, _now());
        assertEq(pool.unlocks(), 1);
        assertEq(pool.swaps(), 1);
        assertEq(pool.settlements(), 1);
        assertEq(pool.takes(), 1);
        assertEq(imd.allowance(address(minter), address(m)), 0);
    }

    function _callbackFault(uint8 fault, bytes4 reason) internal {
        (uint256 total, uint256 cost) = minter.quote(1);
        uint256 bal = alice.balance;
        uint256 next = m.nextId();
        uint256 supply = imd.totalSupply();
        pool.setFault(fault);
        if (reason == bytes4(0)) vm.expectRevert();
        else vm.expectRevert(reason);
        vm.prank(alice);
        minter.mint{value: cost}(1, total, _now());
        _assertCleanFailure(bal, next, supply);
        _retry(total, cost);
    }

    function test_missingCallbackRollsBackAndCanRetry() public {
        _callbackFault(1, EthMinter.BadCallback.selector);
    }

    function test_duplicateCallbackRollsBackAndCanRetry() public {
        _callbackFault(2, EthMinter.BadCallback.selector);
    }

    function test_malformedCallbackDataRollsBackAndCanRetry() public {
        _callbackFault(3, bytes4(0));
    }

    function _externalFault(bytes4 selector) internal {
        (uint256 total, uint256 cost) = minter.quote(1);
        uint256 bal = alice.balance;
        uint256 next = m.nextId();
        uint256 supply = imd.totalSupply();
        vm.mockCallRevert(address(pool), abi.encodeWithSelector(selector), "pool failure");
        vm.expectRevert();
        vm.prank(alice);
        minter.mint{value: cost}(1, total, _now());
        _assertCleanFailure(bal, next, supply);
        _retry(total, cost);
    }

    function test_swapFailureRollsBackAndCanRetry() public {
        _externalFault(IEthPoolManager.swap.selector);
    }

    function test_settlementFailureRollsBackAndCanRetry() public {
        _externalFault(IEthPoolManager.settle.selector);
    }

    function test_takeFailureRollsBackAndCanRetry() public {
        _externalFault(IEthPoolManager.take.selector);
    }

    function test_poolManagerReadFailureRollsBackAndCanRetry() public {
        _externalFault(IEthQuoter.poolManager.selector);
    }

    function _delta(int128 eth, int128 output) internal pure returns (int256) {
        return (int256(eth) << 128) | int256(uint256(uint128(output)));
    }

    function _badDelta(int128 eth, int128 output, bytes4 reason) internal {
        (uint256 total, uint256 cost) = minter.quote(1);
        uint256 supply = imd.totalSupply();
        uint256 bal = alice.balance;
        uint256 next = m.nextId();
        vm.mockCall(
            address(pool), abi.encodeWithSelector(IEthPoolManager.swap.selector), abi.encode(_delta(eth, output))
        );
        vm.expectRevert(reason);
        vm.prank(alice);
        minter.mint{value: cost}(1, total, _now());
        _assertCleanFailure(bal, next, supply);
        _retry(total, cost);
    }

    function test_positiveEthDeltaRejectedBeforeSettlement() public {
        _badDelta(1, int128(int256(BASE)), EthMinter.PartialFill.selector);
    }

    function test_zeroEthDeltaRejectedBeforeSettlement() public {
        _badDelta(0, int128(int256(BASE)), EthMinter.PartialFill.selector);
    }

    function test_negativeImdDeltaRejectedBeforeSettlement() public {
        _badDelta(-1, -1, EthMinter.PartialFill.selector);
    }

    function test_shortOutputRejectedBeforeSettlement() public {
        _badDelta(-1, int128(int256(BASE - 1)), EthMinter.PartialFill.selector);
    }

    function test_excessOutputRejectedBeforeSettlement() public {
        _badDelta(-1, int128(int256(BASE + 1)), EthMinter.PartialFill.selector);
    }

    function test_minimumSignedEthLaneCannotOverflowOrSpendBaseline() public {
        _badDelta(type(int128).min, int128(int256(BASE)), EthMinter.NotEnoughEth.selector);
    }

    function test_staleImdQuoteCannotChargeHigherPrice() public {
        (uint256 total, uint256 cost) = minter.quote(1);
        _mint(bob, 1);
        uint256 before = alice.balance;
        vm.expectRevert(EthMinter.TooExpensive.selector);
        vm.prank(alice);
        minter.mint{value: cost}(1, total, _now());
        assertEq(alice.balance, before);
        assertEq(pool.unlocks(), 0);
        assertEq(m.minted(), 1);
    }

    function test_staleEthQuoteCannotSpendMoreThanCurrentBudget() public {
        (uint256 total, uint256 cost) = minter.quote(1);
        pool.setRate(0.007 ether);
        uint256 before = alice.balance;
        vm.expectRevert(EthMinter.NotEnoughEth.selector);
        vm.prank(alice);
        minter.mint{value: cost}(1, total, _now());
        assertEq(alice.balance, before);
        assertEq(m.minted(), 0);
        assertEq(pool.unlocks(), 0);
    }

    function test_expiryIsInclusiveAndNextSecondFails() public {
        (uint256 total, uint256 cost) = minter.quote(1);
        uint256 expiry = _now();
        vm.prank(alice);
        minter.mint{value: cost}(1, total, expiry);
        vm.warp(expiry + 1);
        vm.expectRevert(EthMinter.QuoteExpired.selector);
        vm.prank(alice);
        minter.mint{value: cost}(1, type(uint256).max, expiry);
        assertEq(m.minted(), 1);
    }

    function test_forcedEthAndImdDonationsRemainAtBaseline() public {
        vm.deal(address(minter), 3 ether);
        imd.mint(address(minter), 7 ether);
        (uint256 total, uint256 cost) = minter.quote(1);
        uint256 before = alice.balance;
        vm.prank(alice);
        minter.mint{value: cost + 1 ether}(1, total, _now());
        assertEq(before - alice.balance, cost);
        assertEq(address(minter).balance, 3 ether);
        assertEq(imd.balanceOf(address(minter)), 7 ether);
        assertEq(imd.allowance(address(minter), address(m)), 0);
    }

    function test_machineFailureRollsBackSwapExpiredRoundAndPrizes() public {
        for (uint256 i; i < 75; ++i) {
            _mint(bob, 20);
        }
        uint256 winner = _grant(alice, G.CAP);
        _place(alice, winner, 0, 0, -2);
        vm.warp(_round().deadline);
        (uint256 total, uint256 cost) = minter.quote(1);
        uint256 bal = alice.balance;
        uint256 next = m.nextId();
        uint256 supply = imd.totalSupply();
        uint256 pot = _round().pot;
        uint256 reserve = m.reserve();
        vm.mockCallRevert(
            address(imd),
            abi.encodeWithSelector(IERC20.transferFrom.selector, address(minter), address(m)),
            "transfer unavailable"
        );
        vm.expectRevert();
        vm.prank(alice);
        minter.mint{value: cost}(1, total, _now());
        _assertCleanFailure(bal, next, supply);
        assertEq(m.round(), 1);
        assertEq(_round().pot, pot);
        assertEq(m.reserve(), reserve);
        assertEq(m.credit(winner), 0);
        _retry(total, cost);
        assertEq(m.round(), 2);
    }

    function test_uint128SignedOutputLimitIsCheckedInQuoteAndMint() public {
        vm.mockCall(
            address(m),
            abi.encodeWithSelector(IdentityMachine.quote.selector),
            abi.encode(uint256(uint128(type(int128).max)) + 1)
        );
        vm.expectRevert(EthMinter.TooExpensive.selector);
        minter.quote(1);
        vm.expectRevert(EthMinter.TooExpensive.selector);
        minter.mint(1, type(uint256).max, _now());
        assertEq(pool.unlocks(), 0);
    }

    function _assertBadPool(EthMinter checkout) internal {
        uint256 before = alice.balance;
        vm.expectRevert(EthMinter.BadPool.selector);
        checkout.quote(1);
        vm.expectRevert(EthMinter.BadPool.selector);
        vm.prank(alice);
        checkout.mint{value: 1 ether}(1, BASE, _now());
        vm.expectRevert(EthMinter.BadPool.selector);
        vm.prank(alice);
        checkout.mintWithReferral{value: 1 ether}(1, BASE, _now(), bob);
        assertEq(alice.balance, before);
        assertEq(address(checkout).balance, 0);
        assertEq(imd.balanceOf(address(checkout)), 0);
        assertEq(imd.allowance(address(checkout), address(m)), 0);
        assertEq(m.minted(), 0);
        assertEq(m.referralBalance(bob), 0);
        if (address(pool).code.length != 0) assertEq(pool.unlocks(), 0);
    }

    // Launch constructors cannot depend on external pool code. Both entry points must still validate it.
    function test_missingPoolManagerIsRejectedOnUse() public {
        address absent = makeAddr("absent pool manager");
        vm.mockCall(address(pool), abi.encodeWithSelector(IEthQuoter.poolManager.selector), abi.encode(absent));
        EthMinter checkout = new EthMinter(m, IEthPoolManager(absent), IEthQuoter(address(pool)), 10_000, 100);
        _assertBadPool(checkout);
    }

    function test_missingQuoterIsRejectedOnUse() public {
        EthMinter checkout =
            new EthMinter(m, IEthPoolManager(address(pool)), IEthQuoter(makeAddr("absent quoter")), 10_000, 100);
        _assertBadPool(checkout);
    }

    function test_wrongQuoterManagerIsRejectedOnUse() public {
        CallbackPool other = new CallbackPool(imd);
        EthMinter checkout = new EthMinter(m, IEthPoolManager(address(pool)), IEthQuoter(address(other)), 10_000, 100);
        _assertBadPool(checkout);
    }

    function test_dependenciesCanAppearAfterDeploymentAndMintWithoutPriorQuote() public {
        bytes memory runtime = address(pool).code;
        vm.etch(address(pool), "");
        EthMinter checkout = new EthMinter(m, IEthPoolManager(address(pool)), IEthQuoter(address(pool)), 10_000, 100);
        _assertBadPool(checkout);
        vm.etch(address(pool), runtime);
        assertEq(pool.unlocks(), 0);

        uint256 total = m.quote(1);
        uint256 cost = (total * pool.rate() + 1 ether - 1) / 1 ether;
        uint256 before = alice.balance;
        vm.prank(alice);
        (uint256 first, uint256 paid) = checkout.mintWithReferral{value: cost + 1 ether}(1, total, _now(), bob);
        assertEq(paid, cost);
        assertEq(pool.unlocks(), 1);
        assertEq(before - alice.balance, cost);
        assertEq(m.minted(), 1);
        (address owner,) = m.pending(first);
        assertEq(owner, alice);
        assertEq(m.referralBalance(bob), total * m.REFERRAL() / m.BPS());
        assertEq(address(checkout).balance, 0);
        assertEq(imd.balanceOf(address(checkout)), 0);
        assertEq(imd.allowance(address(checkout), address(m)), 0);
        (uint256 nextTotal, uint256 nextCost) = checkout.quote(1);
        assertEq(nextTotal, m.quote(1));
        assertGt(nextCost, 0);
    }

    function test_successfulQuoteDoesNotBypassLaterPoolValidation() public {
        minter.quote(1);
        vm.mockCall(address(pool), abi.encodeWithSelector(IEthQuoter.poolManager.selector), abi.encode(address(m)));
        _assertBadPool(minter);
    }

    function test_constructorRejectsMissingMachineAndInvalidFeeSpacing() public {
        vm.expectRevert(EthMinter.BadPool.selector);
        new EthMinter(m, IEthPoolManager(address(pool)), IEthQuoter(address(pool)), 1_000_000, 100);
        vm.expectRevert(EthMinter.BadPool.selector);
        new EthMinter(m, IEthPoolManager(address(pool)), IEthQuoter(address(pool)), 10_000, 0);
        vm.expectRevert(EthMinter.BadPool.selector); // unsigned for the swarm's constructor arguments; must fit int24
        new EthMinter(m, IEthPoolManager(address(pool)), IEthQuoter(address(pool)), 10_000, uint24(type(int24).max) + 1);
        assertEq(
            new EthMinter(m, IEthPoolManager(address(pool)), IEthQuoter(address(pool)), 10_000, uint24(type(int24).max))
                .tickSpacing(),
            type(int24).max
        );
        vm.expectRevert(EthMinter.BadPool.selector);
        new EthMinter(
            IdentityMachine(address(0)), IEthPoolManager(address(pool)), IEthQuoter(address(pool)), 10_000, 100
        );
    }
}
