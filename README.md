# Reins

**Policy-bound execution vaults for AI agents on Robinhood Chain.**

Give an AI agent the keys to trade your tokenized stocks without giving it your stocks.

Reins is a small, auditable set of contracts that lets an owner hand an agent a *scoped key* to a personal vault of Robinhood Stock Tokens (plain ERC-20s with Chainlink feeds). The key says what the agent may trade, where, how much per day in USD, how much value it may lose on any single swap, and until when. The owner keeps custody, can revoke or pause at any time, and withdrawals never pass through the agent.

Built for the Arbitrum Open House Singapore buildathon. Deployed on Robinhood Chain (Arbitrum Orbit).

## Why

Agentic trading and agentic commerce need a way for a person to delegate execution to software they do not fully trust. Today the options are "give the agent the private key" or "sign every transaction yourself". Neither works for an always-on agent managing a stock-token portfolio or paying for services on the owner's behalf.

Robinhood Chain makes the problem concrete: 190+ US equities as ERC-20s, each with a live Chainlink price feed. That feed is what makes a *USD-denominated* policy enforceable on-chain.

## What the vault enforces

| Rule | Where it is checked |
|---|---|
| Only the owner deposits/withdraws/grants/revokes/pauses | `onlyOwner` |
| The agent may only touch allowlisted tokens, routers and payees | per-grant allowlists, snapshotted under a fresh `grantId` so re-granting never inherits an old list |
| The agent may move at most `dailyCapUsd` per rolling 24h window | notional priced by Chainlink before execution |
| A swap may not lose more than `maxSlippageBps` of value | output valued by Chainlink **after** execution; the agent's own `minAmountOut` is not trusted |
| A router only ever gets approval for exactly `amountIn`, reset after the call | `forceApprove` scoping + balance-delta accounting |
| No spending on a stale or non-positive price | oracle reverts instead of returning a wrong number |
| Revoke / pause takes effect immediately | `_authorize` on every agent call |

The last two rows are what stop a compromised agent or a malicious router from draining the vault: the worst case is bounded by `dailyCapUsd × maxSlippageBps` per day, and the owner can cut that to zero with one transaction.

## Contracts

```
src/
  ReinsVault.sol             per-owner vault: custody, policy grants, agentSwap / agentPay
  ReinsFactory.sol           deploys minimal-proxy vaults (EIP-1167)
  ChainlinkStockOracle.sol   token -> Chainlink feed registry, USD valuation with staleness checks
  interfaces/IPriceOracle.sol   the vault depends on this, not on Chainlink directly
  mocks/                     MockERC20, MockFeed, FairRouter (oracle-priced demo DEX), RogueRouter (adversarial)
```

Agent-facing surface is two functions:

```solidity
function agentSwap(SwapRequest calldata req) external returns (uint256 amountOut);
function agentPay(address token, address to, uint256 amount) external;
```

## Tests

23 tests, all green.

- `test/ReinsVault.t.sol` — 21 unit tests: custody, happy paths, every policy rejection, window rollover, re-grant isolation, adversarial routers (partial return, zero return, over-pull), stale feed, and a fuzz test that spending never exceeds the cap.
- `test/Fork.t.sol` — 2 tests on a **fork of Robinhood Chain mainnet** using the real TSLA and AAPL Stock Token contracts and the real Chainlink `TSLA/USD` and `AAPL/USD` feeds: prices are read live, a ~$500 swap succeeds, the next ~$600 swap is rejected by the $1,000 daily cap.

```bash
forge test                                                              # unit
ROBINHOOD_MAINNET_RPC=https://rpc.mainnet.chain.robinhood.com forge test --match-contract RobinhoodForkTest -vv
```

## Demo (reproducible in ~1 minute)

```bash
anvil &                                                                 # local chain
DEPLOYER_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
  forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
./demo/run_demo.sh
```

The demo walks through: create vault → deposit 10 TSLA → grant the agent `$1,000/day, 1% slippage, TSLA↔AAPL` → agent swaps 2 TSLA (ok) → agent tries 4 more TSLA (reverts, cap) → agent pays a merchant 0.5 TSLA (ok) → owner revokes (agent locked out) → owner withdraws.

A reference agent loop in `agent/rebalance.mjs` (viem) reads the policy, computes a rebalance toward a target allocation, clamps it to today's remaining allowance, and executes:

```bash
cd agent && npm install && cd ..
VAULT=<vault from demo> node agent/rebalance.mjs          # DRY_RUN=1 to only print the plan
```

## Deployments

**Robinhood Chain testnet (chain id 46630)** — all sources verified on Blockscout.

| Contract | Address |
|---|---|
| ChainlinkStockOracle | [`0xDFB796EB0213aecAdC740Fc49eE30A5FDbdBFB66`](https://explorer.testnet.chain.robinhood.com/address/0xDFB796EB0213aecAdC740Fc49eE30A5FDbdBFB66) |
| ReinsFactory | [`0xb114edbACb67b912e1981d1206337d6A6906DE4e`](https://explorer.testnet.chain.robinhood.com/address/0xb114edbACb67b912e1981d1206337d6A6906DE4e) |
| ReinsVault implementation | [`0x7E068Bc00928F62b312435A109BDd5e1f6CF7d67`](https://explorer.testnet.chain.robinhood.com/address/0x7E068Bc00928F62b312435A109BDd5e1f6CF7d67) |
| FairRouter (demo DEX) | [`0x5322F1309d5080B5e387C26A44b556933F974a9c`](https://explorer.testnet.chain.robinhood.com/address/0x5322F1309d5080B5e387C26A44b556933F974a9c) |
| TSLA / AAPL / NVDA demo tokens | `0xBA7B0314EbbB17F786BC7a69eB0f997BC566Ea3F` / `0x5e3C9094483E6263A38559Af4Fa5B17Daae3e753` / `0xE6E49fe146F5BafB0dec4D670E709EC74e745C01` |

The full demo was run on testnet against vault [`0x8B7EDa130B54c89aeea454018CAe0dE7b95e62f8`](https://explorer.testnet.chain.robinhood.com/address/0x8B7EDa130B54c89aeea454018CAe0dE7b95e62f8): [deposit](https://explorer.testnet.chain.robinhood.com/tx/0x14de5fdefa3873c67ee5a72efcb1f2326083c923646ee34384b9c48000b5f473) → [grant](https://explorer.testnet.chain.robinhood.com/tx/0xab90bedc04a672f3b46d6e768717825535dbe50b4f2f2851ba4a8db8f6f5d8ce) → [agentSwap](https://explorer.testnet.chain.robinhood.com/tx/0x9d5a0d55f690138c7af88c7a1d64347fec2ff9e93b469df1117d18ba678a6886) → over-cap swap reverted → [agentPay](https://explorer.testnet.chain.robinhood.com/tx/0x74801417ceb2b9219b6e35e275eecf477f014df72a7b14907e13ae7300f7931e) → [revoke](https://explorer.testnet.chain.robinhood.com/tx/0xd30db7994bb4e1116c1db1ed6376dc87c3d05b7bce517c6c9a7deb863b80d028) → [withdraw](https://explorer.testnet.chain.robinhood.com/tx/0xe4b7b8b80508924f3787cdcbc78463863630e2b061b170dd9fcae4db3b6146a0).

Testnet has no Chainlink equity feeds or stock-token liquidity yet, so the Deploy script also ships demo Stock Tokens with feeds seeded from Robinhood's public price API and an oracle-priced demo router. On mainnet (4663) only the oracle + factory are deployed and real feeds are registered.

```bash
TESTNET_DEPLOYER_KEY=0x<throwaway key with testnet ETH> ./deploy_testnet.sh
```

## Design notes

- **Oracle-checked execution, not trust in calldata.** The agent builds router calldata itself (any DEX works), but the vault measures balance deltas and values the output with Chainlink. The policy's loss bound holds even if the router lies.
- **USD caps, not token caps.** A cap of "$1,000/day" is meaningful across 190 stocks; "3 TSLA/day" is not. Chainlink per-stock feeds on Robinhood Chain make this cheap.
- **Grant snapshots.** Allowlists are keyed by `(agent, grantId, kind, address)`. Re-granting bumps `grantId`, so stale permissions cannot leak into a new policy.
- **Fail closed.** Stale price, paused vault, expired key, unknown token — every one reverts. An agent that cannot price a trade cannot make it.
- **Corporate actions.** Robinhood adjusts stock-token supply via a multiplier on splits/dividends. The Chainlink feeds are per-token, so USD valuation stays correct; the REST `/prices` endpoint is *not* multiplier-adjusted, which is why the vault never uses it.

## Roadmap

1. Register the real Robinhood Chain mainnet feeds in a deployed oracle; integrate an on-chain DEX router (Uniswap on Robinhood Chain) in the reference agent.
2. ERC-7715-style permission export so wallets can display a Reins grant as a readable "session key".
3. Multi-agent vaults with per-agent caps sharing one custody balance; time-of-day and market-hours rules.
4. Vibekit plugin so any Arbitrum DeFi agent can act through a Reins vault.

## Security

Unaudited. Testnet only. Do not deposit real assets.

## License

MIT
