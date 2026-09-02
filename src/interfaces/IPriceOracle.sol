// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Values token amounts in USD (18 decimals). The vault depends on this abstraction,
///         not on Chainlink directly, so the feed source can be swapped without touching policy logic.
interface IPriceOracle {
    /// @return usd18 USD value of `amount` of `token`, scaled to 18 decimals.
    function valueUsd(address token, uint256 amount) external view returns (uint256 usd18);
    function isSupported(address token) external view returns (bool);
}
