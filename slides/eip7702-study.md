---
marp: true
theme: default
paginate: true
header: "EIP-7702 × ExchangeDeposit 検証レポート"
footer: "社内勉強会"
style: |
  section {
    font-size: 24px;
  }
  h1 {
    font-size: 36px;
  }
  h2 {
    font-size: 30px;
  }
  code {
    font-size: 18px;
  }
  pre {
    font-size: 16px;
  }
  table {
    font-size: 20px;
  }
---

# EIP-7702 × ExchangeDeposit 検証レポート

**さらばsweep！さらばcollect！**
**既存の EOA 入金アドレスをスマートアカウント化できるか？**

Sepolia テストネットでの実験結果

---

## 背景・課題

### 現行の入金方式

- ユーザーごとに **EOA（普通のアドレス）** を入金アドレスとして発行
- 入金検知: 各 EOA を **個別に監視** する必要がある
- 資金回収: 各 EOA から **個別に送金 TX** を発行（秘密鍵で署名）

### 課題

- EOA が増えるほど **監視・回収の運用コストが増大**
- イベントログによる一括監視ができない
- 各 EOA の秘密鍵管理が必要

### やりたいこと

- 入金アドレスにスマートコントラクトのロジックを持たせたい
- **イベントログで一括監視** / **自動転送** を実現したい

---

## アプローチ: ExchangeDeposit を参考に

### bitbank の ExchangeDeposit コントラクト

- 取引所向けのデポジット管理コントラクト（OSS）
- **Proxy + CALL パターン** でイベント集約を実現
- 今回はこの仕組みを参考に、EIP-7702 との組み合わせを検証

### 2つのアプローチ

| | ExchangeDeposit Proxy 方式 | EIP-7702 方式 |
|:--|:--|:--|
| 概要 | CREATE2 で Proxy をデプロイ | 既存 EOA にコードを委任 |
| アドレス | 新規コントラクトアドレス | **既存 EOA をそのまま使う** |

→ EIP-7702 なら **既存の EOA 入金アドレスをそのままスマートアカウント化** できる可能性

---

## ExchangeDeposit の仕組み（1/3）

### Proxy のバイトコード動作

```
calldatasize == 0 の場合:
  → CALL(ExchangeDeposit, msg.value)
  → ExchangeDeposit.receive() が実行される
  → msg.sender = Proxyアドレス

calldatasize > 0 の場合:
  → DELEGATECALL(ExchangeDeposit, msg.data)
  → gatherErc20() 等の関数を Proxy のコンテキストで実行
```

### ポイント: CALL パターン

ETH送金時は **CALL** なので、`msg.sender` にProxyアドレスが入り、
ExchangeDeposit 本体のコンテキストで `Deposit` イベントが発火する。

---

## ExchangeDeposit の仕組み（2/3）

### receive() の処理フロー

```solidity
receive() external payable {
    require(coldAddress != address(0), 'I am dead :-(');
    require(msg.value >= minimumInput, 'Amount too small');
    (bool success, ) = coldAddress.call{ value: msg.value }('');
    require(success, 'Forwarding funds failed');
    emit Deposit(msg.sender, msg.value);
}
```

1. `coldAddress` が生きているか確認
2. `minimumInput`（0.01 ETH）以上か確認
3. **coldAddress に ETH を自動転送**
4. `Deposit(receiver, amount)` イベントを発火

→ 入金と同時に **コールドウォレットへの自動転送 + ログ記録** が実現

---

## ExchangeDeposit の仕組み（3/3）

### thisAddress (immutable) vs coldAddress (storage)

```
┌─────────────────────────────────────────────────┐
│ ExchangeDeposit 本体 (0x605a...)                │
│                                                 │
│  immutable: thisAddress = address(this)          │
│  immutable: adminAddress                        │
│  storage:   coldAddress = 0xEF7E...             │
│  storage:   minimumInput = 1e16                 │
│  storage:   implementation                      │
└─────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────┐
│ Proxy (0x7842...)                               │
│                                                 │
│  バイトコードに ExchangeDeposit アドレスを埋込   │
│  → CALLで ExchangeDeposit に転送                │
│  → イベントは ExchangeDeposit 本体に記録         │
└─────────────────────────────────────────────────┘
```

- **immutable**: バイトコードに埋め込まれる → どのコンテキストでも読める
- **storage**: コントラクトごとに独立 → Proxy/EOA からは読めない

---

## イベント集約の仕組み（現行 EOA 方式との比較）

```
【現行】各EOA個別監視                  【ExchangeDeposit】イベント集約

User → ETH → EOA_1  ← 個別監視       User → ETH → Proxy_1
User → ETH → EOA_2  ← 個別監視                      │ CALL
User → ETH → EOA_3  ← 個別監視       User → ETH → Proxy_2
  :           :                                      │ CALL
                                                     ▼
                                        ExchangeDeposit 本体 ← 一括監視
                                          emit Deposit(proxy_addr, amount)
                                          coldAddress.call{value}()
                                                     ▼
                                              coldAddress（コールドウォレット）
```

- 全 Proxy の入金イベントが **ExchangeDeposit 本体アドレス1つ** に集まる
- `eth_getLogs` 1回で全入金を検知可能

---

## EIP-7702 とは（1/2）

### 概要

- **Pectra upgrade**（2025年5月）で導入
- EOA に **コントラクトコードを委任** する仕組み
- EOA のコードフィールドに `0xef0100{address}` が設定される
- EOA が **スマートアカウント** として振る舞える

### Type 4 トランザクション

```
TransactionType = 0x04

fields: [chain_id, nonce, max_priority_fee, max_fee,
         gas_limit, to, value, data, access_list,
         authorization_list]  ← NEW
```

---

## EIP-7702 とは（2/2）

### authorization_list

```
authorization_list: [
  { chain_id, address, nonce, y_parity, r, s }
]
```

- 各 EOA が「このコントラクトに委任する」という **署名** を提出
- 署名: `keccak256(0x05 || rlp([chain_id, address, nonce]))` → ECDSA
- **1TX で複数 EOA** の delegation を設定可能
- delegation 設定者 ≠ TX 送信者（ガス支払い者）でもOK

### delegation の解除

```bash
# address(0) を指定すると delegation 解除
cast send <TO> --auth 0x0000...0000 --private-key <KEY>
```

→ 既存 EOA のアドレスを変えずに、**コードを付けたり外したり**できる

---

## 検証結果 1: delegation 基本動作 ✅

### 既存 EOA → ExchangeDeposit Proxy に delegate → ETH 送金

```bash
# テストEOA を既存 Proxy にdelegate
cast send 0xd9909d...52252 \
  --auth 0x7842449503ceefb51a4a33557a804a2d9339517b \
  --value 0.0001ether \
  --private-key $KEY \
  --rpc-url $RPC
```

**結果:** Deposit イベントが発火。ETH が coldAddress に自動転送された。

### delegation 確認

```bash
cast code 0xd9909d...52252 --rpc-url $RPC
# → 0xef01007842449503ceefb51a4a33557a804a2d9339517b
```

→ **EOA が Proxy と同じ動作をするようになった**

---

## 検証結果 2: イベント集約 ✅

### CALL パターンによるイベント集約が EOA でも動作

```
User → ETH送金 → delegated EOA（元は普通のEOA）
                   │
                   │ Proxyバイトコードが実行される
                   │ calldatasize==0 → CALL
                   ▼
            ExchangeDeposit 本体
              │ receive() → emit Deposit(eoa_addr, amount)
              ▼
           coldAddress
```

- delegated EOA への ETH 送金で **ExchangeDeposit 本体に Deposit イベント**が記録
- `eth_getLogs(ExchangeDeposit)` で **一括監視** が実現
- `Deposit.receiver` = delegated EOA アドレス（= 既存の入金アドレス）

---

## 検証結果 3: delegation chain ❌

### EOA → EOA → Contract のチェーンは不可

```
テストEOA #5
  └─ delegate → テストEOA #4 (既に Proxy にdelegate済み)
                  └─ delegate → Proxy (Contract)
```

```
結果: ETH 送金時に
  "invalid opcode: opcode 0xef not defined"
  でリバート
```

- delegation 設定自体は成功する（コード `0xef0100{eoa}` が入る）
- しかし実行時、delegate 先が EOA の場合は
  `0xef0100...` のバイトコードを実行しようとして失敗
- **delegate 先は実際のコントラクトでなければならない**

---

## 検証結果 4: receive() 回避 ✅

### delegation 設定 TX の to アドレスの選び方

| to アドレス | receive() 発火 | 備考 |
|:--|:--|:--|
| 自分自身 (EOA) | **発火する** | minimumInput チェックに注意 |
| coldAddress | **発火しない** | 推奨 |
| address(0) | **発火しない** | 問題なし |

```bash
# to=coldAddress で delegation（receive() 回避）
cast send 0xEF7E36C95aA677174C6edEE052Da64E009165018 \
  --auth 0x7842449503ceefb51a4a33557a804a2d9339517b \
  --private-key $KEY --rpc-url $RPC
```

**ポイント:** authorization は TX 実行前に処理されるので、
to をどこにしても delegation は正しく設定される。

---

## 検証結果 5: バッチ delegation ✅

### 1TX で複数 EOA を一括 delegate（既存 EOA を一括変換）

```solidity
// script/BatchDelegate.s.sol (Foundry)
vm.signAndAttachDelegation(delegateTarget, keyA);
vm.signAndAttachDelegation(delegateTarget, keyB);
vm.signAndAttachDelegation(delegateTarget, keyC);

vm.startBroadcast();
address(0).call("");  // 空のcallでauthorizationだけ処理
vm.stopBroadcast();
```

- `cast` 単体では **複数 authorization を1TXに含められない**
- **Forge Script** + `vm.signAndAttachDelegation` で実現可能
- ガス支払い者（sender）と delegation 対象の EOA は別でOK

→ 大量の既存 EOA を **バッチで一気にスマートアカウント化** できる

---

## 検証結果 6: storage vs immutable

### delegated EOA での storage 読み取り

```
┌─────────────────────────────────────────────────┐
│ delegated EOA（元は普通の入金アドレス）           │
│                                                 │
│  code: 0xef0100{Proxy address}                  │
│  storage: 空（EOA なので何もない）               │
│                                                 │
│  Proxy のバイトコードが実行されるが…             │
│  → immutable (バイトコード埋込) → 読める ✅      │
│  → storage (コントラクト固有)   → 空 ⚠️          │
└─────────────────────────────────────────────────┘
```

- Proxy バイトコードに埋め込まれた **ExchangeDeposit アドレス（immutable 相当）** は読める
- EOA の **storage は空** なので、storage に依存する処理は動かない
- ExchangeDeposit Proxy の `receive()` は **CALL で本体に飛ぶ**ので問題なし

---

## 検証結果 7: ExchangeDeposit 本体に直接 delegate ❌

### Proxy ではなく本体に delegate した場合

```
EOA --delegate-→ ExchangeDeposit 本体
                  │
                  │ receive() 実行（EOA のコンテキスト）
                  │ coldAddress を storage から読む
                  │ → 空（EOA の storage）
                  │ → coldAddress == address(0)
                  │ → "I am dead :-(" で revert ❌
```

- ExchangeDeposit 本体は `coldAddress` を **storage** から読む
- EOA の storage は空なので `coldAddress == address(0)` → revert
- **Proxy に delegate するのが正解**
  （Proxy は CALL パターンで本体の storage を参照する）

---

## 実運用に向けた課題

### 1. 既存 EOA の秘密鍵で authorization 署名が必要

- EIP-7702 の delegation 設定には **各 EOA の秘密鍵による署名** が必要
- 署名サーバへの EIP-7702 authorization 署名機能の実装

### 2. バッチ delegation のツール整備

- `cast` 単体では非対応 → **Forge Script** が必要
- 本番では専用ツール or SDK での実装が必要

### 3. ExchangeDeposit コントラクトのデプロイ

- ExchangeDeposit 本体 + Proxy（delegate先）のデプロイが必要
- coldAddress / adminAddress の設定

### 4. delegation の永続性

- EOA から TX を送ると nonce が変わるが、delegation は維持される
- ただし EOA の秘密鍵で **delegation 解除も可能** → 鍵管理が重要

---

## 現行 EOA 方式 vs ExchangeDeposit Proxy vs EIP-7702 比較

| 項目 | 現行 EOA | ED Proxy (CREATE2) | EIP-7702 |
|:--|:--|:--|:--|
| **アドレス** | EOA | 新規コントラクト | **既存 EOA** |
| **デプロイ** | 不要 | ~50,000 gas/個 | 不要 |
| **delegation** | - | - | ~25,000 gas/個 |
| **バッチ** | - | 1TX1個 | **1TXで複数可** |
| **入金検知** | 個別監視 | **一括 (eth_getLogs)** | **一括 (eth_getLogs)** |
| **自動転送** | なし | **あり (coldAddress)** | **あり (coldAddress)** |
| **秘密鍵** | 必要 | 不要 | 必要 (auth署名) |
| **解除可能** | - | 不可 | **可能** |
| **チェーン要件** | なし | なし | **Pectra 必須** |

---

## まとめ

### 動くこと ✅

- 既存 EOA → Proxy に delegate → ETH 入金で Deposit イベント発火
- **イベント集約**: `eth_getLogs` 1回で全入金を一括監視可能
- **バッチ delegation**: 1TX で複数 EOA を一括スマートアカウント化
- delegation 設定時の receive() 回避（to=coldAddress / address(0)）

### 動かないこと ❌

- delegation chain（EOA → EOA → Contract）
- ExchangeDeposit 本体への直接 delegate（storage が空で revert）

### 結論

- EIP-7702 で **既存 EOA 入金アドレスを変えずに** スマートアカウント化が可能
- ExchangeDeposit の Proxy パターンとの組み合わせで **一括監視 + 自動転送** を実現
- 導入には **署名サーバ整備** と **Pectra 対応チェーン** が前提

---

## Appendix: Sepolia テストアドレス

| 用途 | Address |
|:--|:--|
| adminAddress (*) | `0x88b289ef07B30354e17797a37D5b724840868B62` |
| ExchangeDeposit | `0x605ac676044D591E4eCD5d6C18606c237134a7Dc` |
| Proxy (CREATE2) | `0x7842449503ceefb51a4a33557a804a2d9339517b` |
| coldAddress | `0xEF7E36C95aA677174C6edEE052Da64E009165018` |
| DepositLogic v1 | `0x3F45b7dDF4438424b41500Fee8a327fd19c7bf3C` |
| DepositLogic v2 (CALL版) | `0xb8bfa4cad0555eec9c7e965543eb0eb0f665e107` |
| テストEOA #1 | `0x8301deFb55637FEf8cA18CB24D0432e1913B2bf2` |
| テストEOA #3 | `0xd9909dBAcB1D2eb6A84F704c93218B60B3b52252` |
| テストEOA #5 (chain test) | `0x23b4E056A050965A20B45c91449CB43B81656657` |

(*) adminAddress = deploy元アドレス（コントラクトのオーナー権限）
