# EIP-7702 Experiment on Sepolia

## アドレス・鍵対応表

| 用途 | Address | Private Key |
|------|---------|-------------|
| 自分のアドレス | `0x88b289ef07B30354e17797a37D5b724840868B62` | (MetaMask) |
| coldAddress | `0xEF7E36C95aA677174C6edEE052Da64E009165018` | (MetaMask) |
| ExchangeDeposit (Sepolia) | `0x605ac676044D591E4eCD5d6C18606c237134a7Dc` | - (contract) |
| ProxyFactory | (Remix deploy) | - (contract) |
| Proxy (CREATE2) | `0x7842449503ceefb51a4a33557a804a2d9339517b` | - (contract) |
| DepositLogic v1 (直接emit) | `0x3F45b7dDF4438424b41500Fee8a327fd19c7bf3C` | - (contract) |
| CentralDeposit | `0xa896121013e9053b82bc7ea7d26e4d61739f3404` | - (contract) |
| DepositLogic v2 (CALL版) | `0xb8bfa4cad0555eec9c7e965543eb0eb0f665e107` | - (contract) |
| テストEOA #1 | `0x8301deFb55637FEf8cA18CB24D0432e1913B2bf2` | `0xe26ab0e43886f8608a793d068110318fba5a095ea8df6eefd846b17e0fa707d4` |
| テストEOA #2 | `0x3184a4A6de34895a891ebE4b4C1c60dBAD384942` | `0xa60a1582a2d7415f83df1cd40e05745862d506c9c26c6e1d7d3aa479ccf71e41` |
| テストEOA #3 | `0xd9909dBAcB1D2eb6A84F704c93218B60B3b52252` | `0xc742066364f589d1f43e543c1082cc5b75a3e0b9d7cdc12924862f611857f0b1` |
| テストEOA #4 | `0x2Bfe691000CDDe56c92D2D060B3C4621ba55Df52` | `0x0b9dbba09f28683818df22f63d40c01a95b72ca8f134d5ee8f41d69419214c11` |
| テストEOA #5 (chain test) | `0x23b4E056A050965A20B45c91449CB43B81656657` | `0xdd6d5c434ea22670b64a10a1088eeadd3ec868bb1b5a0181478d339398e52af5` |
| テストEOA #6 (addr(0) test) | `0xd32aDb3451675C8C9e833b4c942fec3F226EC3d4` | `0xfb5c3783aa690865da8365cadb709e3326476872a8b242c33ef856b9e0f75614` |

## castコマンド一覧

### cast共通パス
```
CAST=/Users/skmtkytr/.config/.foundry/bin/cast
RPC=https://ethereum-sepolia-rpc.publicnode.com
```

### 1. EOA生成
```bash
cast wallet new
```
新しいEOAキーペアを生成。テストごとに新しいEOAを作成した。

### 2. 残高確認
```bash
cast balance <ADDRESS> --rpc-url $RPC --ether
```

### 3. EIP-7702 delegation設定（基本形: to=自分自身）
```bash
# テストEOA #1 → DepositLogic v1 にdelegate
# DepositLogic v1は直接emitするので、イベントはEOAアドレスに出る
cast send 0x8301deFb55637FEf8cA18CB24D0432e1913B2bf2 \
  --auth 0x3F45b7dDF4438424b41500Fee8a327fd19c7bf3C \
  --private-key 0xe26ab0e43886f8608a793d068110318fba5a095ea8df6eefd846b17e0fa707d4 \
  --rpc-url $RPC
```
**結果:** type:4 TX成功。EOAにコード `0xef0100{contract}` が設定される。
**注意:** to=自分自身だと delegation設定後にreceive()が発火する（value 0で）。

### 4. delegation確認
```bash
cast code <DELEGATED_EOA> --rpc-url $RPC
```
`0xef0100{delegate先アドレス}` が返ればdelegation設定済み。

### 5. 既存Proxyコントラクトにdelegate（to=自分自身 + value付き）
```bash
# テストEOA #3 → 既存Proxy(CREATE2)にdelegate
# Proxyのreceive()はExchangeDepositにCALLするので、minimumInput以上のvalueが必要
cast send 0xd9909dBAcB1D2eb6A84F704c93218B60B3b52252 \
  --auth 0x7842449503ceefb51a4a33557a804a2d9339517b \
  --value 0.0001ether \
  --private-key 0xc742066364f589d1f43e543c1082cc5b75a3e0b9d7cdc12924862f611857f0b1 \
  --rpc-url $RPC
```
**結果:** 成功。Depositイベントが ExchangeDeposit(`0x605a...`)に集約される。
Proxyの `CALL` パターンにより、exchangeDepositのProxy方式と同じイベント集約が実現。

### 6. delegation設定でreceive()を回避する（to=別アドレス）
```bash
# テストEOA #4 → 既存Proxyにdelegate
# to=coldAddress にすることで、EOA自身のreceive()は発火しない
# value 0でもOK
cast send 0xEF7E36C95aA677174C6edEE052Da64E009165018 \
  --auth 0x7842449503ceefb51a4a33557a804a2d9339517b \
  --private-key 0x0b9dbba09f28683818df22f63d40c01a95b72ca8f134d5ee8f41d69419214c11 \
  --rpc-url $RPC
```
**結果:** 成功。logs空、receive()発火なし。
**ポイント:** authorizationはTX実行前に処理されるので、toをどこにしてもdelegationは設定される。

### 7. to=address(0) でのdelegation設定
```bash
# テストEOA #6 → Proxyにdelegate
# to=address(0) でも問題なくdelegation設定できる
cast send 0x0000000000000000000000000000000000000000 \
  --auth 0x7842449503ceefb51a4a33557a804a2d9339517b \
  --private-key 0xfb5c3783aa690865da8365cadb709e3326476872a8b242c33ef856b9e0f75614 \
  --rpc-url $RPC
```
**結果:** 成功。address(0)宛でも問題なし。

### 8. delegationチェーン（EOA → EOA → Contract）テスト
```bash
# テストEOA #5 → テストEOA #4 (既にProxyにdelegate済み) にdelegate
cast send 0xEF7E36C95aA677174C6edEE052Da64E009165018 \
  --auth 0x2Bfe691000CDDe56c92D2D060B3C4621ba55Df52 \
  --private-key 0xdd6d5c434ea22670b64a10a1088eeadd3ec868bb1b5a0181478d339398e52af5 \
  --rpc-url $RPC
```
**結果:** delegation設定自体は成功するが、ETH送金時に `invalid opcode: opcode 0xef not defined` でリバート。
**結論:** delegationチェーンは辿らない。delegate先は実際のコントラクトである必要がある。

### 9. delegation解除
```bash
cast send <TO> \
  --auth 0x0000000000000000000000000000000000000000 \
  --private-key <KEY> \
  --rpc-url $RPC
```
**未実行だが:** `--auth address(0)` でdelegationを解除できる。

## 実験まとめ

### DepositLogic v1（直接emit）
- receive()内で直接 `emit Deposit()` + `coldAddress.transfer()`
- イベントは各EOAアドレスに出る → EOAごとに個別監視が必要

### DepositLogic v2（CALL版）/ 既存Proxy
- receive()内で `CALL` → ExchangeDeposit
- イベントは ExchangeDeposit本体に集約 → 1アドレスで全入金監視可能
- 既存のProxy(CREATE2)にdelegateするだけで新コントラクトデプロイ不要

### delegation設定のtoアドレス
- `to=自分自身`: receive()が発火する（minimumInputチェックに注意）
- `to=coldAddress / address(0) / 任意`: receive()回避。推奨。

### delegationチェーン
- EOA → EOA → Contract は不可。1段階のみ。

### delegateしたEOAからの送金
- 送信元のdelegationは影響しない。gasUsed=21000の通常送金。
