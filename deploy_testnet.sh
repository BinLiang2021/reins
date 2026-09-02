#!/usr/bin/env bash
# Deploy Reins to Robinhood Chain testnet (chain id 46630) with a throwaway deployer key.
# Never use a wallet that holds real funds here. Get testnet ETH at https://faucet.testnet.chain.robinhood.com
#
#   TESTNET_DEPLOYER_KEY=0x... ./deploy_testnet.sh
set -euo pipefail
cd "$(dirname "$0")"
: "${TESTNET_DEPLOYER_KEY:?set TESTNET_DEPLOYER_KEY (throwaway key with testnet ETH)}"
RPC=${RPC_URL:-https://rpc.testnet.chain.robinhood.com}
# Seed demo feeds from Robinhood's public price API (bid, 8 decimals). Falls back to defaults in the script.
price() { curl -sf "https://api.robinhood.com/rhj/prices/$1" | python3 -c "import sys,json; d=json.load(sys.stdin); print(int(float(d.get('bid') or d.get('price') or 0)*1e8))" 2>/dev/null || echo 0; }
export PRICE_TSLA=$(price TSLA) PRICE_AAPL=$(price AAPL) PRICE_NVDA=$(price NVDA)
for v in PRICE_TSLA PRICE_AAPL PRICE_NVDA; do [ "${!v}" = "0" ] && unset $v; done
DEPLOYER_KEY=$TESTNET_DEPLOYER_KEY forge script script/Deploy.s.sol --rpc-url "$RPC" --broadcast -vv
echo "explorer: https://explorer.testnet.chain.robinhood.com"
