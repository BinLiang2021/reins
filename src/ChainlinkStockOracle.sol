// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";

/// @title ChainlinkStockOracle
/// @notice Token -> Chainlink feed registry that prices ERC-20 stock tokens in USD.
///         Robinhood Chain publishes one Chainlink feed per Stock Token, so a token's USD value
///         is simply amount * feed price. Stale or non-positive answers revert rather than
///         returning a wrong number: a policy cap that cannot be priced must not be spent.
contract ChainlinkStockOracle is IPriceOracle, Ownable2Step {
    struct FeedConfig {
        AggregatorV3Interface feed;
        uint32 heartbeat; // max seconds between feed updates before we treat the price as stale
        uint8 feedDecimals;
        uint8 tokenDecimals;
    }

    /// @dev Equity feeds pause over weekends/holidays; a grace period on top of the heartbeat avoids
    ///      bricking the vault the moment a heartbeat is missed by a few minutes.
    uint256 public constant STALENESS_GRACE = 1 hours;

    mapping(address token => FeedConfig) private _feeds;

    event FeedSet(address indexed token, address indexed feed, uint32 heartbeat);

    error FeedNotSet(address token);
    error StalePrice(address token, uint256 updatedAt);
    error InvalidPrice(address token, int256 answer);
    error InvalidHeartbeat();

    constructor(address admin) Ownable(admin) {}

    function setFeed(address token, AggregatorV3Interface feed, uint32 heartbeat) external onlyOwner {
        if (heartbeat == 0) revert InvalidHeartbeat();
        _feeds[token] = FeedConfig({
            feed: feed,
            heartbeat: heartbeat,
            feedDecimals: feed.decimals(),
            tokenDecimals: IERC20Metadata(token).decimals()
        });
        emit FeedSet(token, address(feed), heartbeat);
    }

    function feedOf(address token) external view returns (FeedConfig memory) {
        return _feeds[token];
    }

    function isSupported(address token) public view returns (bool) {
        return address(_feeds[token].feed) != address(0);
    }

    /// @return price18 USD price of one whole token, 18 decimals.
    function priceUsd(address token) public view returns (uint256 price18) {
        FeedConfig memory cfg = _feeds[token];
        if (address(cfg.feed) == address(0)) revert FeedNotSet(token);
        (, int256 answer,, uint256 updatedAt,) = cfg.feed.latestRoundData();
        if (answer <= 0) revert InvalidPrice(token, answer);
        if (block.timestamp > updatedAt + cfg.heartbeat + STALENESS_GRACE) {
            revert StalePrice(token, updatedAt);
        }
        price18 = uint256(answer) * 1e18 / (10 ** cfg.feedDecimals);
    }

    function valueUsd(address token, uint256 amount) external view returns (uint256 usd18) {
        FeedConfig memory cfg = _feeds[token];
        usd18 = amount * priceUsd(token) / (10 ** cfg.tokenDecimals);
    }
}
