// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPriceOracle} from "../interfaces/IPriceOracle.sol";

/// @notice Demo DEX: fills swaps at oracle price minus a fixed fee, from its own inventory.
///         Stands in for a real AMM on testnet where no stock-token liquidity exists.
contract FairRouter {
    using SafeERC20 for IERC20;

    IPriceOracle public immutable oracle;
    uint16 public immutable feeBps;

    constructor(IPriceOracle oracle_, uint16 feeBps_) {
        oracle = oracle_;
        feeBps = feeBps_;
    }

    function quote(address tokenIn, uint256 amountIn, address tokenOut) public view returns (uint256) {
        uint256 usdIn = oracle.valueUsd(tokenIn, amountIn);
        uint256 usdPerOut = oracle.valueUsd(tokenOut, 1e18);
        return usdIn * (10_000 - feeBps) / 10_000 * 1e18 / usdPerOut;
    }

    function swap(address tokenIn, uint256 amountIn, address tokenOut) external returns (uint256 amountOut) {
        amountOut = quote(tokenIn, amountIn, tokenOut);
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenOut).safeTransfer(msg.sender, amountOut);
    }
}
