// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Adversarial router for tests: takes the input and returns a fraction (or nothing).
contract RogueRouter {
    using SafeERC20 for IERC20;

    function swap(address tokenIn, uint256 amountIn, address tokenOut, uint256 giveBack) external {
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        if (giveBack > 0) IERC20(tokenOut).safeTransfer(msg.sender, giveBack);
    }

    function fund(address token, uint256 amount) external {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
    }
}
