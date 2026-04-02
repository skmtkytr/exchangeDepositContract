---
marp: true
theme: default
paginate: true
header: "入金アドレス管理の移行提案"
footer: "ExchangeDeposit Proxy + EIP-7702"
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

# 入金アドレス管理の移行提案

**ExchangeDeposit Proxy + EIP-7702 による入金検知の刷新**

対象チェーン: Ethereum, Polygon, Avalanche, Flare

---

## Agenda

1. 現行方式の課題
2. 提案: ExchangeDeposit Proxy 方式
3. 入金検知のコスト比較
4. ガス代の負担モデルと損益分岐
5. EIP-7702 による将来の拡張
6. 移行計画
7. リスクと対策
8. 判断ポイント

---

## 現行方式の概要

### ユーザーごとに EOA を発行し、入金を個別監視

```
User → ETH → EOA_1  ← 個別に監視 (debug_trace で全TX解析)
User → ETH → EOA_2  ← 個別に監視
User → ETH → EOA_3  ← 個別に監視
  :           :
              ↓
    定期的に sweep TX を発行して cold wallet へ回収
    (各 EOA の秘密鍵で署名が必要)
```

---

## 現行方式の課題

### 1. ノード負荷・コストが高い

- `debug_traceBlockByNumber` で**ブロック内の全 TX を EVM 再実行**
- Archive node + debug API が必要
- レスポンスサイズ: **数 MB〜数十 MB/ブロック**
- 処理時間: **数秒〜十数秒/ブロック**
- Polygon / Avalanche / Flare はブロック生成が速く、負荷が大きい

### 2. sweep TX のガスコスト

- 各 EOA の残高を個別に cold wallet へ送金
- 1 sweep = 21,000 gas × アクティブアドレス数

### 3. 秘密鍵の管理負荷

- ユーザー数分の EOA 秘密鍵を管理・署名する必要がある

---

## 提案方式: ExchangeDeposit Proxy

### 入金時に自動で cold wallet へ転送 + イベント発火

```
User → ETH → Proxy (ユーザー固有アドレス)
               │
               │ receive() → CALL
               ▼
         ExchangeDeposit 本体
               │
               ├─ emit Deposit(proxy_addr, amount)  ← イベント記録
               │
               ├─ coldAddress.call{value}()          ← 自動転送
               ▼
          Cold Wallet
```

- **sweep TX が不要** — 入金と同時に cold wallet へ転送
- **秘密鍵が不要** — Proxy は Factory がデプロイ
- **イベント集約** — 全入金が 1 つのコントラクトアドレスに記録

---

## 入金検知: debug_trace vs eth_getLogs

### 現行

```
毎ブロック → debug_traceBlockByNumber
           → 全TX の EVM 再実行
           → レスポンス解析 (数MB〜数十MB)
           → 監視アドレスへの送金を抽出
```

### 提案

```
毎ブロック (レンジ指定可) → eth_getLogs(ExchangeDeposit, Deposit)
                         → Bloom filter + インデックス検索
                         → レスポンス (数KB)
                         → 完了
```

---

## internal TX も検知できる理由

### eth_getBlock では見落とすケース

| 送金パターン | eth_getBlock | ExchangeDeposit |
|:--|:--|:--|
| EOA → Proxy (通常送金) | 検知可能 | **Deposit イベントで検知** |
| コントラクト → Proxy (internal TX) | **検知不可** | **Deposit イベントで検知** |
| Multisig → Proxy | **検知不可** | **Deposit イベントで検知** |
| DEX aggregator → Proxy | **検知不可** | **Deposit イベントで検知** |

- Proxy の `receive()` は**送金元が EOA でもコントラクトでも発火**する
- debug_trace と同等の検知精度を、eth_getLogs のコストで実現

---

## コスト比較: リクエスト量

### 全4チェーン月間合計

| | debug_trace (現行) | eth_getLogs (提案) |
|:--|:--|:--|
| **リクエスト数** | ~4,250,000 | ~42,000 (レンジ100) |
| **データ転送量** | TB 級 | GB 級 |
| **ブロック処理時間** | 数秒〜十数秒 | 数 ms〜数十 ms |

- リクエスト数: **約 1/100**
- 帯域: **2〜3 桁の削減**

---

## コスト比較: ノード要件

| | 現行 | 提案 |
|:--|:--|:--|
| **ノード種別** | Archive node | Full node |
| **API 要件** | debug namespace (上位プラン) | eth namespace (標準) |
| **ディスク** | 数 TB (Archive) | 数百 GB (Full) |
| **SaaS プラン** | 上位プランまたは有料アドオン | 標準プラン (無料枠の可能性あり) |

- Archive node → Full node への移行で**インフラコストも削減**
- debug API 非対応のプロバイダでも利用可能に
  - 特に Avalanche / Flare で恩恵が大きい

---

## コスト比較: sweep TX の廃止

### 現行: 定期的に sweep TX を発行

```
各 EOA → cold wallet
  21,000 gas × アクティブアドレス数 × sweep 頻度
```

### 提案: 入金時に自動転送

```
ExchangeDeposit の receive() 内で
  coldAddress.call{value: msg.value}()
→ 追加の TX 不要
```

### Ethereum での sweep コスト例 (30 gwei)

| アクティブユーザー数 | 月1回 sweep のコスト |
|:--|:--|
| 10,000 (10%) | 6.3 ETH/月 |
| 50,000 (50%) | 31.5 ETH/月 |
| 100,000 (100%) | 63 ETH/月 |

**→ 提案方式ではこのコストがゼロになる**

---

## 追加メリット

### ダストアタック / アドレスポイズニング対策

```solidity
require(msg.value >= minimumInput, 'Amount too small');
// minimumInput = 0.01 ETH (admin が変更可能)
```

- 現行 EOA: 送られてくる ETH を拒否できない
- ExchangeDeposit: **minimumInput 未満の送金は revert**
- ダスト送金がコントラクトレベルで拒否される

### リアルタイム検知

- `eth_subscribe("logs")` で WebSocket プッシュ通知が可能
- ポーリング間隔に依存しないリアルタイム入金検知

---

## Proxy デプロイのガスコスト

### 1 ユーザーあたりのセットアップコスト

| チェーン | gas (Proxy デプロイ) | コスト目安 |
|:--|:--|:--|
| **Ethereum** (30 gwei) | 70,000 | 0.0021 ETH |
| **Polygon** | 70,000 | 極小 |
| **Avalanche** | 70,000 | 小 (AVAX 価格に依存) |
| **Flare** | 70,000 | 極小 |

- **Ethereum 以外はコストがほぼ無視できる**
- Ethereum のコストが判断上の主要な論点

---

## ガス代の負担モデル

| 方式 | メリット | デメリット |
|:--|:--|:--|
| **取引所が全額負担** | UX 最良 | Ethereum で初期投資が必要 |
| **初回入金から差し引き** | 追加手続き不要 | 少額入金時に問題 |
| **入金手数料に上乗せ** | ユーザーの抵抗感が少ない | 回収に時間がかかる |
| **lazy deploy** | 未使用アドレスの無駄を回避 | 初回入金にやや遅延 |

### チェーンごとの方針

- **Polygon / Flare**: 取引所全額負担（コストが極小）
- **Avalanche**: 取引所全額負担（AVAX 価格次第では要検討）
- **Ethereum**: lazy deploy or 初回入金差し引き

---

## 損益分岐 (Ethereum, 10万ユーザー)

```
初期コスト:
  Proxy デプロイ: 100,000 × 70,000 gas × 30 gwei = 210 ETH

月間削減 (sweep TX 廃止のみ):
  アクティブ率 10%: 6.3 ETH/月
  アクティブ率 50%: 31.5 ETH/月

損益分岐の目安:
  アクティブ率 10%: 210 / 6.3  ≈ 33 ヶ月
  アクティブ率 50%: 210 / 31.5 ≈  7 ヶ月
```

- RPC コスト削減・運用工数削減を加味すると回収は早まる
- lazy deploy なら初期コストは分散される
- Ethereum 以外のチェーンは即座にコスト削減効果が出る

---

## EIP-7702: 将来の拡張オプション

### 既存 EOA をそのままスマートアカウント化

| | Proxy 方式 (今回の提案) | EIP-7702 方式 (将来) |
|:--|:--|:--|
| **アドレス** | 新規コントラクトアドレス | **既存 EOA をそのまま使用** |
| **セットアップ gas** | ~70,000 (デプロイ) | ~25,000 (delegation) |
| **バッチ処理** | 1TX で 1 Proxy | **1TX で複数 EOA** |
| **秘密鍵** | 不要 | 必要 (authorization 署名) |
| **チェーン要件** | なし | **Pectra upgrade 必須** |

- 入金検知ロジック (eth_getLogs) は**両方式で共通**
- バックエンドの変更は不要。オンチェーンのセットアップのみ異なる

---

## EIP-7702: Sepolia での検証結果

| 検証項目 | 結果 |
|:--|:--|
| 既存 EOA → Proxy に delegate → Deposit イベント発火 | **✅** |
| eth_getLogs でイベント集約 | **✅** |
| 1TX で複数 EOA をバッチ delegate | **✅** |
| delegated EOA で gatherEth() | **✅** |
| delegation chain (EOA → EOA → Contract) | **❌** |
| ExchangeDeposit 本体に直接 delegate | **❌** |

- 基本動作は検証済み
- Pectra 対応チェーンが広がれば、Proxy → EIP-7702 への段階移行が可能

---

## 移行計画

### Phase 1: Proxy 方式の導入 (全チェーン)

1. ExchangeDeposit + ProxyFactory をデプロイ (各チェーン 1 回)
2. 新規ユーザーに Proxy アドレスを発行
3. 入金検知を eth_getLogs に切り替え
4. 既存ユーザーには新しい入金アドレスを案内

### Phase 2: 並行運用期間

5. 旧 EOA (debug_trace) と新 Proxy (eth_getLogs) を並行監視
6. 旧 EOA への入金が十分に減少したら debug_trace を停止
7. Archive node の縮退・廃止

### Phase 3: EIP-7702 への段階移行 (Pectra 対応後)

8. Pectra 対応済みチェーンから EIP-7702 delegation を開始
9. 既存 EOA ユーザーを delegation で移行（アドレス変更不要）
10. Proxy ユーザーはそのまま継続

---

## 移行時のユーザー影響

### 入金アドレスの変更

- **新規ユーザー**: 最初から Proxy アドレスを発行。影響なし
- **既存ユーザー**: 入金アドレスの更新が必要

### 対応策

| 施策 | 内容 |
|:--|:--|
| **段階的な案内** | UI 上で新しい入金アドレスへの切り替えを促す |
| **並行運用期間** | 旧アドレスも一定期間監視を継続（debug_trace） |
| **EIP-7702 での解消** | Pectra 対応後、既存 EOA をそのまま delegate すればアドレス変更不要 |

---

## リスクと対策

| リスク | 影響度 | 対策 |
|:--|:--|:--|
| **コントラクトの脆弱性** | 高 | 監査済みの OSS 実装をベース。追加監査を実施 |
| **コントラクトアドレスへの送金拒否** | 中 | 主要ウォレットは対応済み。問題のあるサービスは個別対応 |
| **ERC20 入金の検知漏れ** | 中 | Transfer イベント監視 + 定期的な gatherErc20() で回収 |
| **selfdestruct による強制送金** | 低 | gatherEth() で回収可能。定期的な残高チェック |
| **ガス代の高騰** | 中 | lazy deploy で分散。L2 チェーンは影響軽微 |
| **EIP-7702 の鍵漏洩** | 高 | 第三者が再 delegate して入金先を乗っ取るリスク。鍵管理の厳格化が前提 |

---

## 判断ポイント

### 導入すべきか

| 観点 | 評価 |
|:--|:--|
| **ノード運用コスト** | Archive node + debug API → Full node。大幅削減 |
| **sweep TX コスト** | ゼロになる。アクティブ率次第で月間数 ETH〜数十 ETH の削減 |
| **入金検知の精度** | debug_trace と同等。internal TX も検知可能 |
| **運用の複雑性** | 秘密鍵管理・sweep 運用が不要に。検知ロジックも簡素化 |
| **初期コスト** | Ethereum で 210 ETH (@10万ユーザー, 30 gwei)。他チェーンはほぼゼロ |

### 次のアクション

- Ethereum のガス代負担方式の決定（全額負担 / lazy deploy / 差し引き）
- コントラクト監査の手配
- 並行運用期間の設計と既存ユーザーへの案内方針

---

## まとめ

### 現行方式の課題

- debug_trace による高コストな入金検知 (Archive node + TB 級の帯域)
- sweep TX のガスコスト (EOA 数に比例)
- 大量の秘密鍵管理

### ExchangeDeposit Proxy で解決できること

- **eth_getLogs による低コスト入金検知** (帯域 2-3 桁削減)
- **入金時の自動転送** (sweep TX 不要)
- **秘密鍵管理の廃止** (Factory が CREATE2 でデプロイ)
- **internal TX の完全検知** (debug_trace 同等の精度)

### 将来の EIP-7702 連携

- **既存 EOA のアドレスを変えずにスマートアカウント化**
- 入金検知ロジック (eth_getLogs) はそのまま。移行コスト最小

---

## Appendix: ExchangeDeposit コントラクト概要

### コア機能

```solidity
// ETH 入金時に自動発火
receive() external payable {
    require(coldAddress != address(0), 'I am dead :-(');
    require(msg.value >= minimumInput, 'Amount too small');
    (bool success, ) = coldAddress.call{ value: msg.value }('');
    require(success, 'Forwarding funds failed');
    emit Deposit(msg.sender, msg.value);
}
```

### 管理機能

| 関数 | 権限 | 用途 |
|:--|:--|:--|
| `changeColdAddress()` | admin | 転送先の変更 |
| `changeMinInput()` | admin | 最低入金額の変更 |
| `changeImplAddr()` | admin | 拡張ロジックの更新 |
| `gatherEth()` | 誰でも | 滞留 ETH の回収 |
| `gatherErc20(token)` | 誰でも | 滞留 ERC20 の回収 |
| `kill()` | admin | コントラクトの無効化 |

---

## Appendix: ERC20 入金の処理フロー

### ETH と異なり、ERC20 は receive() が発火しない

```
User → ERC20.transfer(proxy, amount)
         │
         │ ERC20 の残高が Proxy に加算されるだけ
         │ Proxy のコードは実行されない
         ▼
       Proxy に ERC20 が滞留
         │
         │ バッチ処理で gatherErc20(token) を呼ぶ
         ▼
       coldAddress に ERC20 が転送される
```

### 運用イメージ

1. ERC20 `Transfer` イベントを監視 (to = Proxy アドレス)
2. 滞留トークンを確認
3. `gatherErc20()` をバッチ実行して cold wallet へ回収

---

## Appendix: Proxy のバイトコード動作

### 74 バイトの最小コントラクト

```
calldatasize == 0 の場合 (ETH 送金):
  → CALL(ExchangeDeposit, msg.value)
  → ExchangeDeposit.receive() が実行
  → msg.sender = Proxy アドレス → Deposit イベントに記録

calldatasize > 0 の場合 (関数呼び出し):
  → DELEGATECALL(ExchangeDeposit, msg.data)
  → gatherErc20() 等を Proxy のコンテキストで実行
```

- CALL パターン: イベントが ExchangeDeposit 本体に記録される
- DELEGATECALL パターン: Proxy の残高に対して操作できる
