#!/usr/bin/env bash
# End-to-end Reins demo with cast. Works against a local anvil (default) or Robinhood Chain testnet.
#
#   local:   anvil &  &&  DEPLOYER_KEY=<anvil key #0> forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
#            ./demo/run_demo.sh
#   testnet: RPC_URL=https://rpc.testnet.chain.robinhood.com OWNER_KEY=0x.. AGENT_KEY=0x.. ./demo/run_demo.sh
#
# Requires: foundry (cast), python3. Expects deployments/<chainId>.json from the Deploy script.
set -euo pipefail
cd "$(dirname "$0")/.."

RPC_URL=${RPC_URL:-http://127.0.0.1:8545}
# anvil default accounts #0 / #1 — public test keys, never real funds
OWNER_KEY=${OWNER_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}
AGENT_KEY=${AGENT_KEY:-0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d}
OWNER=$(cast wallet address --private-key "$OWNER_KEY")
AGENT=$(cast wallet address --private-key "$AGENT_KEY")
MERCHANT=${MERCHANT:-0x000000000000000000000000000000000000dEaD}
CHAIN_ID=$(cast chain-id --rpc-url "$RPC_URL")
DEP="deployments/${CHAIN_ID}.json"
[ -f "$DEP" ] || { echo "missing $DEP — run the Deploy script first"; exit 1; }
j() { python3 -c "import json; print(json.load(open('$DEP'))['$1'])"; }
FACTORY=$(j factory); TSLA=$(j TSLA); AAPL=$(j AAPL); ROUTER=$(j router)

send() { cast send --rpc-url "$RPC_URL" --private-key "$1" "${@:2}" >/dev/null; }
call() { cast call --rpc-url "$RPC_URL" "$@" | cut -d' ' -f1; }
usd() { python3 -c "print(f'\${int(\"$1\")/1e18:,.2f}')"; }
units() { python3 -c "print(f'{int(\"$1\")/1e18:,.4f}')"; }
expect_revert() { if cast send --rpc-url "$RPC_URL" --private-key "$@" >/dev/null 2>&1; then echo "   !! unexpected success"; exit 1; fi; }

echo "== chain $CHAIN_ID | owner $OWNER | agent $AGENT"

echo "-- 1. owner creates a vault"
send "$OWNER_KEY" "$FACTORY" "createVault()"
VAULT=$(cast call --rpc-url "$RPC_URL" "$FACTORY" "vaultsOf(address)(address[])" "$OWNER" | tr -d '[] ' | tr ',' '\n' | tail -1)
echo "   vault: $VAULT"

echo "-- 2. owner deposits 10 TSLA"
send "$OWNER_KEY" "$TSLA" "mint(address,uint256)" "$OWNER" 10000000000000000000
send "$OWNER_KEY" "$TSLA" "approve(address,uint256)" "$VAULT" 10000000000000000000
send "$OWNER_KEY" "$VAULT" "deposit(address,uint256)" "$TSLA" 10000000000000000000

echo "-- 3. owner grants the agent a policy: \$1,000/day, 1% max slippage, TSLA<->AAPL via router, 7 days"
EXPIRY=$(( $(date +%s) + 7*24*3600 ))
send "$OWNER_KEY" "$VAULT" \
  "grant(address,(uint64,uint128,uint16,address[],address[],address[]))" \
  "$AGENT" "($EXPIRY,1000000000000000000000,100,[$TSLA,$AAPL],[$ROUTER],[$MERCHANT])"
echo "   remaining allowance: $(usd "$(call "$VAULT" "remainingAllowanceUsd(address)(uint256)" "$AGENT")")"

echo "-- 4. agent swaps 2 TSLA -> AAPL inside the policy"
DATA=$(cast calldata "swap(address,uint256,address)" "$TSLA" 2000000000000000000 "$AAPL")
send "$AGENT_KEY" "$VAULT" "agentSwap((address,uint256,address,uint256,address,bytes))" \
  "($TSLA,2000000000000000000,$AAPL,0,$ROUTER,$DATA)"
echo "   vault TSLA: $(units "$(call "$TSLA" "balanceOf(address)(uint256)" "$VAULT")")   vault AAPL: $(units "$(call "$AAPL" "balanceOf(address)(uint256)" "$VAULT")")"
echo "   remaining allowance: $(usd "$(call "$VAULT" "remainingAllowanceUsd(address)(uint256)" "$AGENT")")"

echo "-- 5. agent tries 4 more TSLA (over the daily cap) -> must revert"
DATA=$(cast calldata "swap(address,uint256,address)" "$TSLA" 4000000000000000000 "$AAPL")
expect_revert "$AGENT_KEY" "$VAULT" "agentSwap((address,uint256,address,uint256,address,bytes))" "($TSLA,4000000000000000000,$AAPL,0,$ROUTER,$DATA)"
echo "   reverted as expected (DailyCapExceeded)"

echo "-- 6. agent pays the merchant 0.5 TSLA (agentic commerce, same cap)"
send "$AGENT_KEY" "$VAULT" "agentPay(address,address,uint256)" "$TSLA" "$MERCHANT" 500000000000000000
echo "   merchant TSLA: $(units "$(call "$TSLA" "balanceOf(address)(uint256)" "$MERCHANT")")"

echo "-- 7. owner revokes; agent is locked out immediately"
send "$OWNER_KEY" "$VAULT" "revoke(address)" "$AGENT"
expect_revert "$AGENT_KEY" "$VAULT" "agentPay(address,address,uint256)" "$TSLA" "$MERCHANT" 1
echo "   reverted as expected (NotAuthorized)"

echo "-- 8. owner withdraws; the agent never had custody"
BAL=$(call "$AAPL" "balanceOf(address)(uint256)" "$VAULT")
send "$OWNER_KEY" "$VAULT" "withdraw(address,uint256,address)" "$AAPL" "$BAL" "$OWNER"
echo "   owner AAPL: $(units "$(call "$AAPL" "balanceOf(address)(uint256)" "$OWNER")")"
echo "== demo complete. vault=$VAULT"
