#!/bin/bash
RPC_URL=${RPC_URL:-"https://ethereum-sepolia-rpc.publicnode.com"}
CONTRACT=${CONTRACT:-"0x605ac676044D591E4eCD5d6C18606c237134a7Dc"}
TOKEN=${TOKEN:-""}       # ERC20 token contract address(es), space-separated (optional)
DECIMALS=${DECIMALS:-18} # ERC20 token decimals (optional, default 18)
FROM_BLOCK=$(printf "0x%x" "${1:-10440192}")
TO_BLOCK=${2:-"latest"}
[[ "$TO_BLOCK" != "latest" ]] && TO_BLOCK=$(printf "0x%x" "$TO_BLOCK")

DEPOSIT_TOPIC="0xe1fffcc4923d04b559f4d29a8bfc6cda04eb5b0d3c460751c2402c5c5cc9109c"
TRANSFER_SIG="0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"

echo "=== ETH Deposits (Deposit event on $CONTRACT) ==="
DEPOSIT_RESP=$(curl -s -X POST "$RPC_URL" \
  -H "Content-Type: application/json" \
  -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getLogs\",\"params\":[{\"address\":\"$CONTRACT\",\"topics\":[\"$DEPOSIT_TOPIC\"],\"fromBlock\":\"$FROM_BLOCK\",\"toBlock\":\"$TO_BLOCK\"}],\"id\":1}")

echo "$DEPOSIT_RESP" | python3 -c "
import sys,json
resp = json.load(sys.stdin)
if 'error' in resp:
    print(f'Error: {resp[\"error\"][\"message\"]}')
    sys.exit(1)
for l in resp['result']:
    proxy = '0x' + l['topics'][1][-40:]
    eth = int(l['data'],16) / 1e18
    block = int(l['blockNumber'],16)
    print(f'Block {block} | {eth:.6f} ETH | proxy {proxy} | tx {l[\"transactionHash\"][:18]}...')
print(f'--- {len(resp[\"result\"])} deposits found ---')
"

if [ -n "$TOKEN" ]; then
  echo ""
  echo "=== ERC20 Gathers (gatherErc20 from proxies/contract) ==="

  # topics[1] OR filter: proxy addresses seen in Deposit events + CONTRACT itself
  # gatherErc20 is called via DELEGATECALL so Transfer.from = proxy address
  FROM_FILTER=$(echo "$DEPOSIT_RESP" | python3 -c "
import sys,json
resp = json.load(sys.stdin)
proxies = set()
if resp.get('result'):
    for l in resp['result']:
        proxies.add('0x' + '0'*24 + l['topics'][1][-40:])
# Include the main contract itself (direct gatherErc20 call without proxy)
proxies.add('0x' + '0'*24 + '${CONTRACT:2}'.lower())
print(json.dumps(sorted(proxies)))
")

  # Build JSON array of token addresses from space-separated TOKEN
  TOKEN_JSON=$(python3 -c "
import sys,json
tokens = '$TOKEN'.split()
print(json.dumps(tokens))
")

  curl -s -X POST "$RPC_URL" \
    -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getLogs\",\"params\":[{\"address\":$TOKEN_JSON,\"topics\":[\"$TRANSFER_SIG\",$FROM_FILTER],\"fromBlock\":\"$FROM_BLOCK\",\"toBlock\":\"$TO_BLOCK\"}],\"id\":2}" \
    | python3 -c "
import sys,json
resp = json.load(sys.stdin)
if 'error' in resp:
    print(f'Error: {resp[\"error\"][\"message\"]}')
    sys.exit(1)
decimals = $DECIMALS
for l in resp['result']:
    from_addr = '0x' + l['topics'][1][-40:]
    to_addr   = '0x' + l['topics'][2][-40:]
    token     = l['address']
    amount    = int(l['data'],16) / (10**decimals)
    block     = int(l['blockNumber'],16)
    print(f'Block {block} | {amount:.6f} tokens ({token[:10]}...) | from {from_addr} | to {to_addr} | tx {l[\"transactionHash\"][:18]}...')
print(f'--- {len(resp[\"result\"])} ERC20 gathers found ---')
"
fi
