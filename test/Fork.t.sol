// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReinsVault} from "../src/ReinsVault.sol";
import {ReinsFactory} from "../src/ReinsFactory.sol";
import {ChainlinkStockOracle} from "../src/ChainlinkStockOracle.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {FairRouter} from "../src/mocks/FairRouter.sol";

/// @notice Runs against a fork of Robinhood Chain mainnet (chain id 4663) using the *real* Stock Token
///         contracts and the *real* Chainlink equity feeds. Skipped when ROBINHOOD_MAINNET_RPC is unset.
///         Nothing here touches a real wallet: balances are injected with `deal`.
contract RobinhoodForkTest is Test {
    // Robinhood Stock Tokens (mainnet) — from https://api.robinhood.com/rhj/assets
    address constant TSLA = 0x322F0929c4625eD5bAd873c95208D54E1c003b2d;
    address constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    // Chainlink feeds on Robinhood Chain — from reference-data-directory (feeds-robinhood-mainnet.json)
    address constant TSLA_USD = 0x4A1166a659A55625345e9515b32adECea5547C38;
    address constant AAPL_USD = 0x6B22A786bAa607d76728168703a39Ea9C99f2cD0;

    address owner = makeAddr("owner");
    address agent = makeAddr("agent");

    ChainlinkStockOracle oracle;
    ReinsVault vault;
    FairRouter fair;

    function setUp() public {
        string memory rpc = vm.envOr("ROBINHOOD_MAINNET_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        require(block.chainid == 4663, "not Robinhood Chain");

        oracle = new ChainlinkStockOracle(address(this));
        // Equity feeds heartbeat is 86400s on Robinhood Chain; markets close over weekends, so allow 3 days.
        oracle.setFeed(TSLA, AggregatorV3Interface(TSLA_USD), 3 days);
        oracle.setFeed(AAPL, AggregatorV3Interface(AAPL_USD), 3 days);

        ReinsFactory factory = new ReinsFactory(oracle);
        vm.prank(owner);
        vault = ReinsVault(factory.createVault());

        fair = new FairRouter(oracle, 30);
        deal(AAPL, address(fair), 10_000e18);
        deal(TSLA, owner, 10e18);

        address[] memory tokens = new address[](2);
        tokens[0] = TSLA;
        tokens[1] = AAPL;
        address[] memory routers = new address[](1);
        routers[0] = address(fair);
        ReinsVault.PolicyInput memory p = ReinsVault.PolicyInput({
            expiry: uint64(block.timestamp + 1 days),
            dailyCapUsd: 1_000e18,
            maxSlippageBps: 100,
            tokens: tokens,
            routers: routers,
            payees: new address[](0)
        });
        vm.startPrank(owner);
        IERC20(TSLA).approve(address(vault), type(uint256).max);
        vault.deposit(TSLA, 10e18);
        vault.grant(agent, p);
        vm.stopPrank();
    }

    modifier onFork() {
        if (address(vault) == address(0)) {
            console2.log("ROBINHOOD_MAINNET_RPC not set; skipping fork test");
            return;
        }
        _;
    }

    function test_fork_realFeedPricesRealStockToken() public view onFork {
        uint256 tslaPrice = oracle.priceUsd(TSLA);
        uint256 aaplPrice = oracle.priceUsd(AAPL);
        console2.log("TSLA/USD (18 dec):", tslaPrice);
        console2.log("AAPL/USD (18 dec):", aaplPrice);
        assertGt(tslaPrice, 10e18, "TSLA price sane");
        assertLt(tslaPrice, 100_000e18, "TSLA price sane");
        assertEq(oracle.valueUsd(TSLA, 1e18), tslaPrice);
    }

    function test_fork_agentSwapWithinCapUsingRealTokens() public onFork {
        uint256 tslaPrice = oracle.priceUsd(TSLA);
        uint256 amountIn = 500e18 * 1e18 / tslaPrice; // ~$500 of TSLA
        bytes memory data = abi.encodeCall(FairRouter.swap, (TSLA, amountIn, AAPL));

        vm.prank(agent);
        uint256 out = vault.agentSwap(
            ReinsVault.SwapRequest({
                tokenIn: TSLA,
                amountIn: amountIn,
                tokenOut: AAPL,
                minAmountOut: 0,
                router: address(fair),
                data: data
            })
        );
        assertEq(IERC20(AAPL).balanceOf(address(vault)), out);
        uint256 remaining = vault.remainingAllowanceUsd(agent);
        assertApproxEqRel(remaining, 500e18, 0.01e18, "about $500 of cap left");

        // Second ~$600 swap must exceed the $1,000/day cap.
        uint256 amountIn2 = 600e18 * 1e18 / tslaPrice;
        vm.prank(agent);
        vm.expectRevert();
        vault.agentSwap(
            ReinsVault.SwapRequest({
                tokenIn: TSLA,
                amountIn: amountIn2,
                tokenOut: AAPL,
                minAmountOut: 0,
                router: address(fair),
                data: abi.encodeCall(FairRouter.swap, (TSLA, amountIn2, AAPL))
            })
        );
    }
}
