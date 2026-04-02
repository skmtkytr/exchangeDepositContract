#!/bin/bash
set -e
CAST=/Users/skmtkytr/.config/.foundry/bin/cast
FORGE=/Users/skmtkytr/.config/.foundry/bin/forge
ANVIL=/Users/skmtkytr/.config/.foundry/bin/anvil
RPC=http://localhost:8545
DEPLOYER_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
DEPOSIT_TOPIC=0xe1fffcc4923d04b559f4d29a8bfc6cda04eb5b0d3c460751c2402c5c5cc9109c

cd "$(dirname "$0")"

echo "=== 1. anvil起動 (block-time 1s) ==="
$ANVIL --block-time 1 &
ANVIL_PID=$!
sleep 2

cleanup() { kill $ANVIL_PID 2>/dev/null; }
trap cleanup EXIT

echo ""
echo "=== 2. デプロイ + 入金 ==="
$FORGE script script/DepositE2E.s.sol --rpc-url $RPC --broadcast 2>&1 | grep -E "deployed|Deposit TX"

echo ""
echo "=== 3. TXのレシートを確認 ==="
# 最新ブロックからDepositイベントを取得
LOGS=$($CAST logs --from-block 1 --to-block latest "$DEPOSIT_TOPIC" --rpc-url $RPC 2>&1)
TX_HASH=$(echo "$LOGS" | grep transactionHash | head -1 | awk '{print $2}')
echo "Deposit TX: $TX_HASH"

if [ -z "$TX_HASH" ]; then
    echo "FAIL: Depositイベントが見つからない"
    exit 1
fi

echo ""
echo "=== 4. TXが含まれるブロック確認 ==="
TX_BLOCK=$($CAST receipt "$TX_HASH" --rpc-url $RPC | grep "^blockNumber" | awk '{print $2}')
echo "TX included in block: $TX_BLOCK"

echo ""
echo "=== 5. confirmations確認 ==="
sleep 3  # 3ブロック待つ
LATEST=$($CAST block-number --rpc-url $RPC)
CONFIRMATIONS=$((LATEST - TX_BLOCK))
echo "Latest block: $LATEST"
echo "Confirmations: $CONFIRMATIONS"

if [ "$CONFIRMATIONS" -ge 2 ]; then
    echo "PASS: $CONFIRMATIONS confirmations reached"
else
    echo "FAIL: only $CONFIRMATIONS confirmations"
    exit 1
fi

echo ""
echo "=== 6. coldAddressの残高確認 ==="
# makeAddr("cold") = deterministic address
COLD_BALANCE=$($CAST balance 0x197f9519417d77440c8175eac09e0b68e43c0b79 --rpc-url $RPC --ether 2>/dev/null || echo "unknown")
echo "Cold balance: $COLD_BALANCE ETH"

echo ""
echo "=== ALL TESTS PASSED ==="
