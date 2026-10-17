// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IdentityMachine} from "./IdentityMachine.sol";

// ABI-compatible with Uniswap v4-core IPoolManager and v4-periphery IV4Quoter.
// https://github.com/Uniswap/v4-periphery/blob/main/src/interfaces/IV4Quoter.sol
struct EthPoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

struct EthSwapParams {
    bool zeroForOne;
    int256 amountSpecified;
    uint160 sqrtPriceLimitX96;
}

struct EthQuoteParams {
    EthPoolKey poolKey;
    bool zeroForOne;
    uint128 exactAmount;
    bytes hookData;
}

interface IEthPoolManager {
    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(EthPoolKey calldata key, EthSwapParams calldata params, bytes calldata hookData)
        external
        returns (int256);
    function settle() external payable returns (uint256);
    function take(address currency, address to, uint256 amount) external;
}

interface IEthQuoter {
    function quoteExactOutputSingle(EthQuoteParams calldata params)
        external
        returns (uint256 amountIn, uint256 gasEstimate);
    function poolManager() external view returns (address);
}

/// @notice One native-ETH transaction: buy exactly the IMD needed, mint to the payer, refund the rest.
/// @dev Fixed hookless pool, no administrator, no user IMD approval, no retained payment funds.
contract EthMinter is ReentrancyGuard {
    using SafeERC20 for IERC20;
    IdentityMachine public immutable machine;
    IERC20 public immutable imd;
    IEthPoolManager public immutable poolManager;
    IEthQuoter public immutable quoter;
    uint24 public immutable fee;
    int24 public immutable tickSpacing;
    bool private awaitingCallback;

    error BadPool();
    error QuoteExpired();
    error TooExpensive();
    error NotEnoughEth();
    error PartialFill();
    error BadCallback();
    error RefundFailed();
    event MintedWithEth(
        address indexed owner, uint256 indexed firstMintId, uint256 count, uint256 imdPaid, uint256 ethPaid
    );

    constructor(IdentityMachine machine_, IEthPoolManager manager_, IEthQuoter quoter_, uint24 fee_, uint24 spacing_) {
        if (
            address(machine_).code.length == 0 || fee_ >= 1_000_000 || spacing_ == 0
                || spacing_ > uint24(type(int24).max)
        ) revert BadPool();
        machine = machine_;
        imd = machine_.imd();
        poolManager = manager_;
        quoter = quoter_;
        fee = fee_;
        tickSpacing = int24(spacing_);
    }

    /// @dev External pool contracts are absent in the launch rehearsal. Validate them at use instead.
    function _checkPool() private view {
        if (
            address(poolManager).code.length == 0 || address(quoter).code.length == 0
                || quoter.poolManager() != address(poolManager)
        ) revert BadPool();
    }

    function poolKey() public view returns (EthPoolKey memory) {
        return EthPoolKey(address(0), address(imd), fee, tickSpacing, address(0));
    }

    /// @dev Run with eth_call; the v4 quoter simulates a swap and is intentionally not a view.
    function quote(uint256 n) external returns (uint256 imdTotal, uint256 ethTotal) {
        if (n == 0 || n > machine.MAX_BATCH()) revert IdentityMachine.BadBatch();
        imdTotal = machine.quote(n);
        if (imdTotal > uint256(uint128(type(int128).max))) revert TooExpensive();
        _checkPool();
        (ethTotal,) = quoter.quoteExactOutputSingle(EthQuoteParams(poolKey(), true, uint128(imdTotal), ""));
    }

    function mint(uint256 n, uint256 maxImd, uint256 expires)
        external
        payable
        nonReentrant
        returns (uint256 firstMintId, uint256 ethPaid)
    {
        return _mint(n, maxImd, expires, address(0));
    }

    /// @notice Referral reward is in IMD, from the machine's existing shared allocation.
    function mintWithReferral(uint256 n, uint256 maxImd, uint256 expires, address referrer)
        external
        payable
        nonReentrant
        returns (uint256 firstMintId, uint256 ethPaid)
    {
        return _mint(n, maxImd, expires, referrer);
    }

    function _mint(uint256 n, uint256 maxImd, uint256 expires, address referrer)
        private
        returns (uint256 firstMintId, uint256 ethPaid)
    {
        if (block.timestamp > expires) revert QuoteExpired();
        if (n == 0 || n > machine.MAX_BATCH()) revert IdentityMachine.BadBatch();
        uint256 total = machine.quote(n);
        if (total > maxImd || total > uint256(uint128(type(int128).max))) revert TooExpensive();
        _checkPool();
        awaitingCallback = true;
        ethPaid = abi.decode(poolManager.unlock(abi.encode(total, msg.value)), (uint256));
        if (awaitingCallback) revert BadCallback();
        imd.forceApprove(address(machine), total);
        (firstMintId,) =
            machine.mintForWithReferral(msg.sender, n, total, referrer == address(this) ? address(0) : referrer);
        uint256 refund = msg.value - ethPaid;
        if (refund != 0) {
            (bool ok,) = msg.sender.call{value: refund}("");
            if (!ok) revert RefundFailed();
        }
        emit MintedWithEth(msg.sender, firstMintId, n, total, ethPaid);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager) || !awaitingCallback) revert BadCallback();
        awaitingCallback = false;
        (uint256 total, uint256 budget) = abi.decode(data, (uint256, uint256));
        // Positive amountSpecified is exact output; the high/low int128 lanes are ETH/IMD deltas.
        int256 delta = poolManager.swap(poolKey(), EthSwapParams(true, int256(total), 4295128740), "");
        int128 ethDelta = int128(delta >> 128);
        int128 imdDelta = int128(delta);
        if (ethDelta >= 0 || imdDelta < 0 || uint256(uint128(imdDelta)) != total) revert PartialFill();
        uint256 spent = uint256(-int256(ethDelta));
        if (spent > budget) revert NotEnoughEth();
        poolManager.settle{value: spent}();
        poolManager.take(address(imd), address(this), total);
        return abi.encode(spent);
    }
}
