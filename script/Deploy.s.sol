// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {ChainlinkStockOracle} from "../src/ChainlinkStockOracle.sol";
import {ReinsFactory} from "../src/ReinsFactory.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockFeed} from "../src/mocks/MockFeed.sol";
import {FairRouter} from "../src/mocks/FairRouter.sol";

/// @notice Deploys the oracle + factory. On testnet/local it also deploys demo Stock Tokens, feeds seeded
///         from Robinhood's public price API (passed in via env), and a FairRouter with inventory —
///         Robinhood Chain testnet has no Chainlink equity feeds or stock-token DEX liquidity yet.
///         Mainnet (4663) deploys only the oracle + factory and expects real feeds to be registered.
contract Deploy is Script {
    struct Demo {
        MockERC20 tsla;
        MockERC20 aapl;
        MockERC20 nvda;
        FairRouter router;
    }

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_KEY");
        address deployer = vm.addr(pk);
        vm.startBroadcast(pk);

        ChainlinkStockOracle oracle = new ChainlinkStockOracle(deployer);
        ReinsFactory factory = new ReinsFactory(oracle);
        console2.log("oracle  ", address(oracle));
        console2.log("factory ", address(factory));

        string memory json = "deployment";
        vm.serializeUint(json, "chainId", block.chainid);
        vm.serializeAddress(json, "oracle", address(oracle));
        string memory out = vm.serializeAddress(json, "factory", address(factory));

        if (block.chainid != 4663) {
            Demo memory d = _deployDemo(oracle);
            vm.serializeAddress(json, "TSLA", address(d.tsla));
            vm.serializeAddress(json, "AAPL", address(d.aapl));
            vm.serializeAddress(json, "NVDA", address(d.nvda));
            out = vm.serializeAddress(json, "router", address(d.router));
        }
        vm.stopBroadcast();

        string memory path = string.concat("deployments/", vm.toString(block.chainid), ".json");
        vm.writeJson(out, path);
        console2.log("wrote", path);
    }

    function _deployDemo(ChainlinkStockOracle oracle) internal returns (Demo memory d) {
        // Prices in 8 decimals, defaulting to values observed on Robinhood's REST API on 2026-09-02.
        d.tsla = _stock(oracle, "Tesla Robinhood Token", "TSLA", vm.envOr("PRICE_TSLA", uint256(300e8)));
        d.aapl = _stock(oracle, "Apple Robinhood Token", "AAPL", vm.envOr("PRICE_AAPL", uint256(200e8)));
        d.nvda = _stock(oracle, "NVIDIA Robinhood Token", "NVDA", vm.envOr("PRICE_NVDA", uint256(150e8)));
        d.router = new FairRouter(oracle, 30);
        d.tsla.mint(address(d.router), 100_000e18);
        d.aapl.mint(address(d.router), 100_000e18);
        d.nvda.mint(address(d.router), 100_000e18);
        console2.log("router  ", address(d.router));
    }

    function _stock(ChainlinkStockOracle oracle, string memory name, string memory symbol, uint256 price8)
        internal
        returns (MockERC20 token)
    {
        token = new MockERC20(name, symbol);
        MockFeed feed = new MockFeed(int256(price8));
        oracle.setFeed(address(token), AggregatorV3Interface(address(feed)), 1 days);
        console2.log(symbol, address(token));
    }
}
