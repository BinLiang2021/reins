// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";

/// @title ReinsVault
/// @notice A personal, non-custodial vault that lets an owner hand an AI agent a *policy-bound* key.
///
///         The owner keeps custody. The agent gets a permission that says:
///           - which tokens it may trade, which routers it may use, which payees it may pay,
///           - how much USD notional it may move per 24h window (priced by Chainlink),
///           - how much value may be lost to slippage on any single swap,
///           - until when the key is valid.
///         Every agent action is checked against the oracle *after* execution too: a swap whose output
///         is worth less than (1 - maxSlippage) of the input reverts, so a compromised agent or a rogue
///         router cannot drain the vault below the policy's loss bound.
///
///         The owner can revoke or pause at any time; withdrawals never pass through the agent.
contract ReinsVault is Initializable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant WINDOW = 1 days;
    uint16 public constant BPS = 10_000;

    enum AllowKind {
        Token,
        Router,
        Payee
    }

    /// @notice What the owner grants. Lists are snapshotted under a fresh grantId, so re-granting
    ///         never inherits an old allowlist by accident.
    struct PolicyInput {
        uint64 expiry;
        uint128 dailyCapUsd; // 18 decimals
        uint16 maxSlippageBps;
        address[] tokens;
        address[] routers;
        address[] payees;
    }

    struct Permission {
        uint64 grantId;
        uint64 expiry;
        uint128 dailyCapUsd;
        uint16 maxSlippageBps;
        uint64 windowStart;
        uint128 spentUsd;
        bool active;
    }

    address public owner;
    IPriceOracle public oracle;
    bool public paused;

    mapping(address agent => Permission) private _permissions;
    mapping(bytes32 key => bool) private _allowed;

    event Deposited(address indexed from, address indexed token, uint256 amount);
    event Withdrawn(address indexed token, address indexed to, uint256 amount);
    event PolicyGranted(
        address indexed agent,
        uint64 indexed grantId,
        uint64 expiry,
        uint128 dailyCapUsd,
        uint16 maxSlippageBps
    );
    event PolicyRevoked(address indexed agent, uint64 indexed grantId);
    event PausedSet(bool paused);
    event AgentSwap(
        address indexed agent,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 notionalUsd,
        address router
    );
    event AgentPayment(
        address indexed agent, address indexed token, address indexed to, uint256 amount, uint256 notionalUsd
    );

    error NotOwner();
    error NotAuthorized(address agent);
    error PolicyExpired(uint64 expiry);
    error VaultPaused();
    error NotAllowed(AllowKind kind, address addr);
    error DailyCapExceeded(uint256 requestedUsd, uint256 remainingUsd);
    error SlippageExceeded(uint256 minValueUsd, uint256 gotValueUsd);
    error InsufficientOutput(uint256 minAmountOut, uint256 received);
    error InputOverspent(uint256 allowed, uint256 spent);
    error RouterCallFailed(bytes reason);
    error ZeroAmount();
    error InvalidPolicy(string reason);
    error SameToken();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(address owner_, IPriceOracle oracle_) external initializer {
        if (owner_ == address(0) || address(oracle_) == address(0)) revert InvalidPolicy("zero address");
        owner = owner_;
        oracle = oracle_;
    }

    // ───────────────────────────── owner: custody ─────────────────────────────

    /// @notice Anyone may top up the vault (e.g. an agent returning revenue); only the owner can take out.
    function deposit(address token, uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit Deposited(msg.sender, token, amount);
    }

    function withdraw(address token, uint256 amount, address to) external onlyOwner {
        if (amount == 0) revert ZeroAmount();
        IERC20(token).safeTransfer(to, amount);
        emit Withdrawn(token, to, amount);
    }

    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
        emit PausedSet(paused_);
    }

    // ───────────────────────────── owner: policy ──────────────────────────────

    function grant(address agent, PolicyInput calldata policy) external onlyOwner {
        if (agent == address(0)) revert InvalidPolicy("zero agent");
        if (policy.expiry <= block.timestamp) revert InvalidPolicy("expiry in the past");
        if (policy.dailyCapUsd == 0) revert InvalidPolicy("zero cap");
        if (policy.maxSlippageBps > BPS) revert InvalidPolicy("slippage > 100%");

        Permission storage p = _permissions[agent];
        uint64 grantId = p.grantId + 1;
        p.grantId = grantId;
        p.expiry = policy.expiry;
        p.dailyCapUsd = policy.dailyCapUsd;
        p.maxSlippageBps = policy.maxSlippageBps;
        p.windowStart = uint64(block.timestamp);
        p.spentUsd = 0;
        p.active = true;

        _allowAll(agent, grantId, AllowKind.Token, policy.tokens);
        _allowAll(agent, grantId, AllowKind.Router, policy.routers);
        _allowAll(agent, grantId, AllowKind.Payee, policy.payees);

        emit PolicyGranted(agent, grantId, policy.expiry, policy.dailyCapUsd, policy.maxSlippageBps);
    }

    function revoke(address agent) external onlyOwner {
        Permission storage p = _permissions[agent];
        p.active = false;
        emit PolicyRevoked(agent, p.grantId);
    }

    // ───────────────────────────── agent: execution ───────────────────────────

    /// @notice What the agent asks the vault to do. `data` is router calldata prepared by the agent;
    ///         the vault approves exactly `amountIn` for the duration of the call and resets it after.
    struct SwapRequest {
        address tokenIn;
        uint256 amountIn;
        address tokenOut;
        uint256 minAmountOut;
        address router;
        bytes data;
    }

    /// @notice Swap through an allowed router, bounded by the daily cap and the oracle-checked loss bound.
    function agentSwap(SwapRequest calldata req) external nonReentrant returns (uint256 amountOut) {
        if (req.amountIn == 0) revert ZeroAmount();
        if (req.tokenIn == req.tokenOut) revert SameToken();
        Permission storage p = _authorize(msg.sender);
        _requireAllowed(msg.sender, p.grantId, AllowKind.Token, req.tokenIn);
        _requireAllowed(msg.sender, p.grantId, AllowKind.Token, req.tokenOut);
        _requireAllowed(msg.sender, p.grantId, AllowKind.Router, req.router);

        uint256 notionalUsd = oracle.valueUsd(req.tokenIn, req.amountIn);
        _spend(p, notionalUsd);

        amountOut = _route(req);

        // Oracle-checked execution: the agent's own minAmountOut is not trusted as the loss bound.
        uint256 minValueUsd = notionalUsd * (BPS - p.maxSlippageBps) / BPS;
        uint256 gotValueUsd = oracle.valueUsd(req.tokenOut, amountOut);
        if (gotValueUsd < minValueUsd) revert SlippageExceeded(minValueUsd, gotValueUsd);

        emit AgentSwap(
            msg.sender, req.tokenIn, req.tokenOut, req.amountIn, amountOut, notionalUsd, req.router
        );
    }

    /// @dev Runs the router call with a scoped approval and measures real balance deltas.
    function _route(SwapRequest calldata req) internal returns (uint256 amountOut) {
        IERC20 tokenIn = IERC20(req.tokenIn);
        IERC20 tokenOut = IERC20(req.tokenOut);
        uint256 inBefore = tokenIn.balanceOf(address(this));
        uint256 outBefore = tokenOut.balanceOf(address(this));

        tokenIn.forceApprove(req.router, req.amountIn);
        (bool ok, bytes memory reason) = req.router.call(req.data);
        if (!ok) revert RouterCallFailed(reason);
        tokenIn.forceApprove(req.router, 0);

        uint256 spentIn = inBefore - tokenIn.balanceOf(address(this));
        if (spentIn > req.amountIn) revert InputOverspent(req.amountIn, spentIn);
        amountOut = tokenOut.balanceOf(address(this)) - outBefore;
        if (amountOut < req.minAmountOut) revert InsufficientOutput(req.minAmountOut, amountOut);
    }

    /// @notice Pay an allowed payee (agentic commerce: settle a bill, buy a service) within the daily cap.
    function agentPay(address token, address to, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        Permission storage p = _authorize(msg.sender);
        _requireAllowed(msg.sender, p.grantId, AllowKind.Token, token);
        _requireAllowed(msg.sender, p.grantId, AllowKind.Payee, to);

        uint256 notionalUsd = oracle.valueUsd(token, amount);
        _spend(p, notionalUsd);
        IERC20(token).safeTransfer(to, amount);
        emit AgentPayment(msg.sender, token, to, amount, notionalUsd);
    }

    // ───────────────────────────── views ──────────────────────────────────────

    function permissionOf(address agent) external view returns (Permission memory) {
        return _permissions[agent];
    }

    /// @notice USD (18 dec) the agent may still spend in the current window, accounting for window rollover.
    function remainingAllowanceUsd(address agent) external view returns (uint256) {
        Permission memory p = _permissions[agent];
        if (!p.active || paused || block.timestamp > p.expiry) return 0;
        if (block.timestamp >= p.windowStart + WINDOW) return p.dailyCapUsd;
        return p.dailyCapUsd - p.spentUsd;
    }

    function isAllowed(address agent, AllowKind kind, address addr) external view returns (bool) {
        return _allowed[_key(agent, _permissions[agent].grantId, kind, addr)];
    }

    // ───────────────────────────── internals ──────────────────────────────────

    function _authorize(address agent) internal view returns (Permission storage p) {
        if (paused) revert VaultPaused();
        p = _permissions[agent];
        if (!p.active) revert NotAuthorized(agent);
        if (block.timestamp > p.expiry) revert PolicyExpired(p.expiry);
    }

    function _spend(Permission storage p, uint256 usd) internal {
        if (block.timestamp >= p.windowStart + WINDOW) {
            p.windowStart = uint64(block.timestamp);
            p.spentUsd = 0;
        }
        uint256 remaining = p.dailyCapUsd - p.spentUsd;
        if (usd > remaining) revert DailyCapExceeded(usd, remaining);
        p.spentUsd += uint128(usd);
    }

    function _allowAll(address agent, uint64 grantId, AllowKind kind, address[] calldata list) internal {
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i] == address(this)) revert InvalidPolicy("vault cannot be allowlisted");
            _allowed[_key(agent, grantId, kind, list[i])] = true;
        }
    }

    function _requireAllowed(address agent, uint64 grantId, AllowKind kind, address addr) internal view {
        if (!_allowed[_key(agent, grantId, kind, addr)]) revert NotAllowed(kind, addr);
    }

    function _key(address agent, uint64 grantId, AllowKind kind, address addr)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(agent, grantId, kind, addr));
    }
}
