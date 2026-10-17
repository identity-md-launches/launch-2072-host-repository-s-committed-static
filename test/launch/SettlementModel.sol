// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {EthPoolKey, EthSwapParams, EthQuoteParams} from "src/EthMinter.sol";

/// Offline dependency model: ordinary 18-decimal transfers, plus the documented IMD blocklist risk.
contract CheckoutToken is ERC20 {
    mapping(address => bool) public blocked;
    error Blocked();

    constructor() ERC20("Checkout test IMD", "IMD") {}

    function mint(address who, uint256 amount) external {
        _mint(who, amount);
    }

    function setBlocked(address who, bool value) external {
        blocked[who] = value;
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (blocked[from] || blocked[to]) revert Blocked();
        super._update(from, to, amount);
    }
}

interface ISettlementCallback {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

/// Models v4's exact-output delta signs and obligation to settle both currencies before unlock returns.
/// This is not a liquidity/price-impact simulator. Tokens come from a finite funded balance, never a swap mint.
contract SettlementPool {
    CheckoutToken public immutable token;
    uint24 public immutable fee;
    int24 public immutable spacing;
    uint256 public rate;
    address public locker;
    uint256 public ethDebt;
    uint256 public tokenCredit;
    uint256 public swaps;
    uint256 public ethSettled;
    uint256 public tokensTaken;

    constructor(CheckoutToken t, uint24 f, int24 s) {
        (token, fee, spacing) = (t, f, s);
    }

    function setRate(uint256 r) external {
        require(r > 0, "zero rate");
        rate = r;
    }

    function cost(uint256 output) public view returns (uint256) {
        return (output * rate + 1 ether - 1) / 1 ether;
    }

    function checkKey(EthPoolKey calldata key) public view {
        require(
            key.currency0 == address(0) && key.currency1 == address(token) && key.hooks == address(0) && key.fee == fee
                && key.tickSpacing == spacing,
            "unexpected pool key"
        );
    }

    function unlock(bytes calldata data) external returns (bytes memory result) {
        require(locker == address(0), "already unlocked");
        locker = msg.sender;
        result = ISettlementCallback(msg.sender).unlockCallback(data);
        require(ethDebt == 0 && tokenCredit == 0, "unsettled currency");
        locker = address(0);
    }

    function swap(EthPoolKey calldata key, EthSwapParams calldata p, bytes calldata hookData)
        external
        returns (int256)
    {
        require(msg.sender == locker && locker != address(0), "not locker");
        checkKey(key);
        require(
            p.zeroForOne && p.amountSpecified > 0 && p.sqrtPriceLimitX96 == 4295128740 && hookData.length == 0,
            "unexpected swap"
        );
        require(ethDebt == 0 && tokenCredit == 0, "pending settlement");
        tokenCredit = uint256(p.amountSpecified);
        ethDebt = cost(tokenCredit);
        require(tokenCredit <= uint128(type(int128).max) && ethDebt <= uint128(type(int128).max), "delta overflow");
        ++swaps;
        return (int256(-int128(int256(ethDebt))) << 128) | int256(tokenCredit);
    }

    function settle() external payable returns (uint256) {
        require(msg.sender == locker && locker != address(0) && msg.value == ethDebt, "bad settlement");
        ethSettled += msg.value;
        ethDebt = 0;
        return msg.value;
    }

    function take(address currency, address recipient, uint256 amount) external {
        require(
            msg.sender == locker && locker != address(0) && currency == address(token) && amount == tokenCredit,
            "bad take"
        );
        tokenCredit = 0;
        tokensTaken += amount;
        require(token.transfer(recipient, amount), "token transfer failed");
    }
}

contract SettlementQuoter {
    SettlementPool public immutable poolManager;

    constructor(SettlementPool p) {
        poolManager = p;
    }

    function quoteExactOutputSingle(EthQuoteParams calldata p) external view returns (uint256, uint256) {
        poolManager.checkKey(p.poolKey);
        require(p.zeroForOne && p.hookData.length == 0, "unexpected quote");
        return (poolManager.cost(p.exactAmount), 50_000);
    }
}
