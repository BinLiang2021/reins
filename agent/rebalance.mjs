// Reference agent: keeps a Reins vault near a target allocation, never exceeding the granted policy.
//
// The vault is the source of truth for what the agent may do. Before every action the agent reads
// `remainingAllowanceUsd` and the allowlists; the chain enforces the same rules again on execution.
//
// Usage (against local anvil after `forge script script/Deploy.s.sol` + `demo/run_demo.sh` step 1-3,
// or against Robinhood Chain testnet with your own keys):
//   RPC_URL=http://127.0.0.1:8545 VAULT=0x... AGENT_KEY=0x... node agent/rebalance.mjs
//
// Optional: TARGET_TSLA_BPS (default 5000 = 50/50 TSLA:AAPL), DRY_RUN=1.
import { createPublicClient, createWalletClient, http, parseAbi, encodeFunctionData, formatUnits } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { readFileSync } from 'node:fs';

const RPC_URL = process.env.RPC_URL ?? 'http://127.0.0.1:8545';
const AGENT_KEY = process.env.AGENT_KEY ?? '0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d';
const TARGET_TSLA_BPS = BigInt(process.env.TARGET_TSLA_BPS ?? '5000');
const DRY_RUN = process.env.DRY_RUN === '1';

const vaultAbi = parseAbi([
  'function oracle() view returns (address)',
  'function remainingAllowanceUsd(address agent) view returns (uint256)',
  'function permissionOf(address agent) view returns ((uint64 grantId,uint64 expiry,uint128 dailyCapUsd,uint16 maxSlippageBps,uint64 windowStart,uint128 spentUsd,bool active))',
  'function isAllowed(address agent, uint8 kind, address addr) view returns (bool)',
  'function agentSwap((address tokenIn,uint256 amountIn,address tokenOut,uint256 minAmountOut,address router,bytes data) req) returns (uint256)',
]);
const oracleAbi = parseAbi(['function valueUsd(address token, uint256 amount) view returns (uint256)']);
const erc20Abi = parseAbi(['function balanceOf(address) view returns (uint256)', 'function symbol() view returns (string)']);
const routerAbi = parseAbi(['function quote(address tokenIn, uint256 amountIn, address tokenOut) view returns (uint256)', 'function swap(address tokenIn, uint256 amountIn, address tokenOut) returns (uint256)']);

const pub = createPublicClient({ transport: http(RPC_URL) });
const account = privateKeyToAccount(AGENT_KEY);
const wallet = createWalletClient({ account, transport: http(RPC_URL) });
const chainId = await pub.getChainId();
const dep = JSON.parse(readFileSync(new URL(`../deployments/${chainId}.json`, import.meta.url)));
const VAULT = process.env.VAULT ?? (() => { throw new Error('set VAULT=<vault address>'); })();
const { TSLA, AAPL, router } = dep;
const usd = (x) => `$${Number(formatUnits(x, 18)).toFixed(2)}`;

const oracle = await pub.readContract({ address: VAULT, abi: vaultAbi, functionName: 'oracle' });
const perm = await pub.readContract({ address: VAULT, abi: vaultAbi, functionName: 'permissionOf', args: [account.address] });
const remaining = await pub.readContract({ address: VAULT, abi: vaultAbi, functionName: 'remainingAllowanceUsd', args: [account.address] });
console.log(`agent ${account.address} on chain ${chainId}`);
console.log(`policy: active=${perm.active} cap=${usd(perm.dailyCapUsd)}/day slippage=${perm.maxSlippageBps}bps remaining=${usd(remaining)}`);
const MIN_TRADE_USD = 10n ** 18n; // ignore sub-$1 dust
if (!perm.active || remaining < MIN_TRADE_USD) { console.log('nothing to do: no usable allowance today'); process.exit(0); }

for (const [kind, addr] of [[0, TSLA], [0, AAPL], [1, router]]) {
  const ok = await pub.readContract({ address: VAULT, abi: vaultAbi, functionName: 'isAllowed', args: [account.address, kind, addr] });
  if (!ok) { console.log(`policy does not allow ${addr}; stopping`); process.exit(0); }
}

const bal = async (t) => pub.readContract({ address: t, abi: erc20Abi, functionName: 'balanceOf', args: [VAULT] });
const val = async (t, a) => pub.readContract({ address: oracle, abi: oracleAbi, functionName: 'valueUsd', args: [t, a] });
const [tslaBal, aaplBal] = await Promise.all([bal(TSLA), bal(AAPL)]);
const [tslaUsd, aaplUsd] = await Promise.all([val(TSLA, tslaBal), val(AAPL, aaplBal)]);
const total = tslaUsd + aaplUsd;
console.log(`holdings: TSLA ${usd(tslaUsd)}  AAPL ${usd(aaplUsd)}  total ${usd(total)}`);
if (total === 0n) process.exit(0);

const targetTslaUsd = (total * TARGET_TSLA_BPS) / 10000n;
const driftUsd = tslaUsd - targetTslaUsd; // >0 sell TSLA, <0 buy TSLA
const [tokenIn, tokenOut, sellUsd] = driftUsd > 0n ? [TSLA, AAPL, driftUsd] : [AAPL, TSLA, -driftUsd];
if (sellUsd < MIN_TRADE_USD) { console.log('within $1 of target; nothing to do'); process.exit(0); }

// Never plan beyond what the policy leaves us today.
const spendUsd = sellUsd < remaining ? sellUsd : remaining;
const inBal = tokenIn === TSLA ? tslaBal : aaplBal;
const inUsd = tokenIn === TSLA ? tslaUsd : aaplUsd;
const amountIn = (inBal * spendUsd) / inUsd;
if (amountIn === 0n) { console.log('computed trade rounds to zero; nothing to do'); process.exit(0); }
const quoted = await pub.readContract({ address: router, abi: routerAbi, functionName: 'quote', args: [tokenIn, amountIn, tokenOut] });
const minAmountOut = (quoted * (10000n - BigInt(perm.maxSlippageBps))) / 10000n;
console.log(`plan: sell ${formatUnits(amountIn, 18)} of ${tokenIn === TSLA ? 'TSLA' : 'AAPL'} (~${usd(spendUsd)}) -> ≥ ${formatUnits(minAmountOut, 18)} ${tokenOut === TSLA ? 'TSLA' : 'AAPL'}`);
if (DRY_RUN) process.exit(0);

const data = encodeFunctionData({ abi: routerAbi, functionName: 'swap', args: [tokenIn, amountIn, tokenOut] });
const hash = await wallet.writeContract({
  address: VAULT, abi: vaultAbi, functionName: 'agentSwap', chain: null,
  args: [{ tokenIn, amountIn, tokenOut, minAmountOut, router, data }],
});
const receipt = await pub.waitForTransactionReceipt({ hash });
console.log(`executed in ${hash} (status ${receipt.status})`);
const after = await pub.readContract({ address: VAULT, abi: vaultAbi, functionName: 'remainingAllowanceUsd', args: [account.address] });
console.log(`remaining allowance now ${usd(after)}`);
