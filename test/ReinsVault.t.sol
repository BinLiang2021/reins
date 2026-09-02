// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ReinsVault} from "../src/ReinsVault.sol";
import {ReinsFactory} from "../src/ReinsFactory.sol";
import {ChainlinkStockOracle} from "../src/ChainlinkStockOracle.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockFeed} from "../src/mocks/MockFeed.sol";
import {FairRouter} from "../src/mocks/FairRouter.sol";
import {RogueRouter} from "../src/mocks/RogueRouter.sol";

contract ReinsVaultTest is Test {
    address owner = makeAddr("owner");
    address agent = makeAddr("agent");
    address stranger = makeAddr("stranger");
    address merchant = makeAddr("merchant");

    ChainlinkStockOracle oracle;
    ReinsFactory factory;
    ReinsVault vault;
    MockERC20 tsla;
    MockERC20 aapl;
    MockERC20 doge; // never allowlisted
    MockFeed tslaFeed;
    MockFeed aaplFeed;
    FairRouter fair;
    RogueRouter rogue;

    uint256 constant TSLA_PRICE = 300e8; // $300
    uint256 constant AAPL_PRICE = 200e8; // $200
    uint128 constant CAP = 1_000e18; // $1,000 / day

    function setUp() public {
        vm.warp(1_800_000_000);
        oracle = new ChainlinkStockOracle(address(this));
        factory = new ReinsFactory(oracle);

        tsla = new MockERC20("Tesla Robinhood Token", "TSLA");
        aapl = new MockERC20("Apple Robinhood Token", "AAPL");
        doge = new MockERC20("Doge", "DOGE");
        tslaFeed = new MockFeed(int256(TSLA_PRICE));
        aaplFeed = new MockFeed(int256(AAPL_PRICE));
        oracle.setFeed(address(tsla), AggregatorV3Interface(address(tslaFeed)), 1 days);
        oracle.setFeed(address(aapl), AggregatorV3Interface(address(aaplFeed)), 1 days);

        fair = new FairRouter(oracle, 30); // 0.3% fee
        rogue = new RogueRouter();
        aapl.mint(address(fair), 1_000_000e18);
        aapl.mint(address(rogue), 1_000_000e18);

        vm.prank(owner);
        vault = ReinsVault(factory.createVault());

        tsla.mint(owner, 100e18);
        vm.startPrank(owner);
        tsla.approve(address(vault), type(uint256).max);
        vault.deposit(address(tsla), 10e18); // $3,000 in the vault
        vault.grant(agent, _policy(uint64(block.timestamp + 7 days), CAP, 100));
        vm.stopPrank();
    }

    // ───────────── helpers ─────────────

    function _policy(uint64 expiry, uint128 cap, uint16 slippageBps)
        internal
        view
        returns (ReinsVault.PolicyInput memory p)
    {
        p.expiry = expiry;
        p.dailyCapUsd = cap;
        p.maxSlippageBps = slippageBps;
        p.tokens = new address[](2);
        p.tokens[0] = address(tsla);
        p.tokens[1] = address(aapl);
        p.routers = new address[](1);
        p.routers[0] = address(fair);
        p.payees = new address[](1);
        p.payees[0] = merchant;
    }

    function _swapReq(uint256 amountIn, address router, bytes memory data)
        internal
        view
        returns (ReinsVault.SwapRequest memory r)
    {
        r.tokenIn = address(tsla);
        r.amountIn = amountIn;
        r.tokenOut = address(aapl);
        r.minAmountOut = 0;
        r.router = router;
        r.data = data;
    }

    function _fairData(uint256 amountIn) internal view returns (bytes memory) {
        return abi.encodeCall(FairRouter.swap, (address(tsla), amountIn, address(aapl)));
    }

    // ───────────── custody ─────────────

    function test_ownerCanWithdraw_agentCannot() public {
        vm.prank(owner);
        vault.withdraw(address(tsla), 1e18, owner);
        assertEq(tsla.balanceOf(owner), 91e18);

        vm.prank(agent);
        vm.expectRevert(ReinsVault.NotOwner.selector);
        vault.withdraw(address(tsla), 1e18, agent);
    }

    function test_initializeTwiceReverts() public {
        vm.expectRevert();
        vault.initialize(stranger, oracle);
    }

    function test_factoryTracksVaults() public {
        vm.prank(owner);
        address second = factory.createVault();
        address[] memory vs = factory.vaultsOf(owner);
        assertEq(vs.length, 2);
        assertEq(vs[1], second);
        assertEq(ReinsVault(second).owner(), owner);
    }

    // ───────────── happy path ─────────────

    function test_agentSwapWithinPolicy() public {
        uint256 amountIn = 2e18; // $600 notional
        vm.prank(agent);
        uint256 out = vault.agentSwap(_swapReq(amountIn, address(fair), _fairData(amountIn)));

        // $600 * 0.997 / $200 = 2.991 AAPL
        assertEq(out, 2.991e18);
        assertEq(aapl.balanceOf(address(vault)), 2.991e18);
        assertEq(tsla.balanceOf(address(vault)), 8e18);
        assertEq(vault.remainingAllowanceUsd(agent), CAP - 600e18);
        assertEq(tsla.allowance(address(vault), address(fair)), 0, "approval must be reset");
    }

    function test_agentPayWithinPolicy() public {
        vm.prank(agent);
        vault.agentPay(address(tsla), merchant, 1e18); // $300
        assertEq(tsla.balanceOf(merchant), 1e18);
        assertEq(vault.remainingAllowanceUsd(agent), CAP - 300e18);
    }

    function test_windowResetsAfter24h() public {
        vm.startPrank(agent);
        vault.agentPay(address(tsla), merchant, 3e18); // $900
        vm.expectRevert(abi.encodeWithSelector(ReinsVault.DailyCapExceeded.selector, 600e18, 100e18));
        vault.agentPay(address(tsla), merchant, 2e18);

        vm.warp(block.timestamp + 1 days);
        assertEq(vault.remainingAllowanceUsd(agent), CAP);
        vault.agentPay(address(tsla), merchant, 2e18); // fresh window
        vm.stopPrank();
        assertEq(tsla.balanceOf(merchant), 5e18);
    }

    // ───────────── policy enforcement ─────────────

    function test_strangerCannotAct() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ReinsVault.NotAuthorized.selector, stranger));
        vault.agentPay(address(tsla), merchant, 1e18);
    }

    function test_capExceededReverts() public {
        uint256 amountIn = 4e18; // $1,200 > $1,000 cap
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(ReinsVault.DailyCapExceeded.selector, 1_200e18, CAP));
        vault.agentSwap(_swapReq(amountIn, address(fair), _fairData(amountIn)));
    }

    function test_tokenNotAllowedReverts() public {
        doge.mint(address(vault), 1e18);
        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(ReinsVault.NotAllowed.selector, ReinsVault.AllowKind.Token, address(doge))
        );
        vault.agentPay(address(doge), merchant, 1e18);
    }

    function test_routerNotAllowedReverts() public {
        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(
                ReinsVault.NotAllowed.selector, ReinsVault.AllowKind.Router, address(rogue)
            )
        );
        vault.agentSwap(_swapReq(1e18, address(rogue), ""));
    }

    function test_payeeNotAllowedReverts() public {
        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(ReinsVault.NotAllowed.selector, ReinsVault.AllowKind.Payee, stranger)
        );
        vault.agentPay(address(tsla), stranger, 1e18);
    }

    function test_expiredPolicyReverts() public {
        vm.warp(block.timestamp + 8 days);
        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(ReinsVault.PolicyExpired.selector, uint64(block.timestamp - 1 days))
        );
        vault.agentPay(address(tsla), merchant, 1e18);
        assertEq(vault.remainingAllowanceUsd(agent), 0);
    }

    function test_revokeStopsAgentImmediately() public {
        vm.prank(owner);
        vault.revoke(agent);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(ReinsVault.NotAuthorized.selector, agent));
        vault.agentPay(address(tsla), merchant, 1e18);
    }

    function test_pauseStopsAgent() public {
        vm.prank(owner);
        vault.setPaused(true);
        vm.prank(agent);
        vm.expectRevert(ReinsVault.VaultPaused.selector);
        vault.agentPay(address(tsla), merchant, 1e18);
        assertEq(vault.remainingAllowanceUsd(agent), 0);
    }

    function test_regrantDoesNotInheritOldAllowlist() public {
        ReinsVault.PolicyInput memory p = _policy(uint64(block.timestamp + 1 days), CAP, 100);
        p.payees = new address[](0); // new grant: no payees
        vm.prank(owner);
        vault.grant(agent, p);
        assertFalse(vault.isAllowed(agent, ReinsVault.AllowKind.Payee, merchant));
        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(ReinsVault.NotAllowed.selector, ReinsVault.AllowKind.Payee, merchant)
        );
        vault.agentPay(address(tsla), merchant, 1e18);
    }

    function test_grantRejectsBadPolicy() public {
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(ReinsVault.InvalidPolicy.selector, "expiry in the past"));
        vault.grant(agent, _policy(uint64(block.timestamp), CAP, 100));
        vm.expectRevert(abi.encodeWithSelector(ReinsVault.InvalidPolicy.selector, "zero cap"));
        vault.grant(agent, _policy(uint64(block.timestamp + 1), 0, 100));
        vm.expectRevert(abi.encodeWithSelector(ReinsVault.InvalidPolicy.selector, "slippage > 100%"));
        vault.grant(agent, _policy(uint64(block.timestamp + 1), CAP, 10_001));
        vm.stopPrank();
    }

    // ───────────── adversarial execution ─────────────

    function test_rogueRouterCannotDrain() public {
        // Owner (mistakenly) allowlists a router that keeps most of the input.
        ReinsVault.PolicyInput memory p = _policy(uint64(block.timestamp + 1 days), CAP, 100);
        p.routers[0] = address(rogue);
        vm.prank(owner);
        vault.grant(agent, p);

        uint256 amountIn = 1e18; // $300 in, router returns $20 of AAPL
        bytes memory data = abi.encodeCall(RogueRouter.swap, (address(tsla), amountIn, address(aapl), 0.1e18));
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(ReinsVault.SlippageExceeded.selector, 297e18, 20e18));
        vault.agentSwap(_swapReq(amountIn, address(rogue), data));
        assertEq(tsla.balanceOf(address(vault)), 10e18, "revert keeps funds in vault");
    }

    function test_routerReturningNothingReverts() public {
        ReinsVault.PolicyInput memory p = _policy(uint64(block.timestamp + 1 days), CAP, 100);
        p.routers[0] = address(rogue);
        vm.prank(owner);
        vault.grant(agent, p);

        bytes memory data = abi.encodeCall(RogueRouter.swap, (address(tsla), 1e18, address(aapl), 0));
        ReinsVault.SwapRequest memory r = _swapReq(1e18, address(rogue), data);
        r.minAmountOut = 1;
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(ReinsVault.InsufficientOutput.selector, 1, 0));
        vault.agentSwap(r);
    }

    function test_stalePriceBlocksSpending() public {
        tslaFeed.setUpdatedAt(block.timestamp - 2 days);
        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(
                ChainlinkStockOracle.StalePrice.selector, address(tsla), block.timestamp - 2 days
            )
        );
        vault.agentPay(address(tsla), merchant, 1e18);
    }

    function test_agentCannotSpendMoreThanApprovedInput() public {
        // Router that pulls more than amountIn would need a larger approval; approval is scoped, so it fails inside.
        vm.prank(agent);
        vm.expectRevert(); // RouterCallFailed(ERC20InsufficientAllowance)
        vault.agentSwap(_swapReq(1e18, address(fair), _fairData(2e18)));
    }

    // ───────────── invariant-ish fuzz ─────────────

    function testFuzz_spendNeverExceedsCap(uint96 a, uint96 b, uint96 c) public {
        uint256[3] memory amounts = [uint256(a) % 5e18, uint256(b) % 5e18, uint256(c) % 5e18];
        uint256 spentUsd;
        for (uint256 i = 0; i < 3; i++) {
            if (amounts[i] == 0) continue;
            uint256 usd = amounts[i] * TSLA_PRICE * 1e18 / 1e8 / 1e18;
            vm.prank(agent);
            if (spentUsd + usd > CAP) {
                vm.expectRevert();
                vault.agentPay(address(tsla), merchant, amounts[i]);
            } else {
                vault.agentPay(address(tsla), merchant, amounts[i]);
                spentUsd += usd;
            }
        }
        assertLe(spentUsd, CAP);
        assertEq(vault.remainingAllowanceUsd(agent), CAP - spentUsd);
    }
}
