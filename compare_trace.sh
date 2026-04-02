#!/bin/bash
RPC_URL=${RPC_URL:-"http://erigon.dappnode:8545"}
TX=${1:-"0x4888f8326215e7e3b8d37bf06464e78cce0e30879290fcce7cf7c3a8f2b62c51"}

echo "=== trace_transaction (OpenEthereum 形式) ==="
curl -s -X POST "$RPC_URL" \
  -H "Content-Type: application/json" \
  -d "{\"jsonrpc\":\"2.0\",\"method\":\"trace_transaction\",\"params\":[\"$TX\"],\"id\":1}" \
  | python3 -c "
import sys,json
resp=json.load(sys.stdin)
if 'error' in resp: print('Error:', resp['error']); sys.exit(1)
for t in resp['result']:
    a=t['action']
    typ=t['type']
    fr=a.get('from','')[:18]
    to=a.get('to','')[:18]
    val=int(a.get('value','0x0'),16)/1e18 if 'value' in a else 0
    depth=len(t.get('traceAddress',[]))
    indent='  '*depth
    print(f'{indent}[{typ}] {fr}.. -> {to}.. | {val:.6f} ETH')
"

echo ""
echo "=== debug_traceTransaction (Geth 形式) ==="
curl -s -X POST "$RPC_URL" \
  -H "Content-Type: application/json" \
  -d "{\"jsonrpc\":\"2.0\",\"method\":\"debug_traceTransaction\",\"params\":[\"$TX\",{\"tracer\":\"callTracer\"}],\"id\":1}" \
  | python3 -c "
import sys,json
resp=json.load(sys.stdin)
if 'error' in resp: print('Error:', resp['error']); sys.exit(1)
def walk(call, depth=0):
    indent='  '*depth
    typ=call.get('type','')
    fr=call.get('from','')[:18]
    to=call.get('to','')[:18]
    val=int(call.get('value','0x0'),16)/1e18
    gas=int(call.get('gasUsed','0x0'),16)
    print(f'{indent}[{typ}] {fr}.. -> {to}.. | {val:.6f} ETH | gas: {gas}')
    for sub in call.get('calls',[]):
        walk(sub, depth+1)
walk(resp['result'])
"
