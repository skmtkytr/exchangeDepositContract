# 入金検知方式の比較分析: debug_trace vs eth_getBlock vs ExchangeDeposit (eth_getLogs)

対象チェーン: Ethereum, Polygon, Avalanche, Flare

## 前提: 3つのアプローチの概要

| | A: `debug_traceBlockByNumber` | B: `eth_getBlockByNumber` | C: `eth_getLogs` (ExchangeDeposit) |
|---|---|---|---|
| **原理** | ブロック内全TXをEVM再実行し internal call を含む全送金をトレース | ブロック内のトップレベルTXのみ取得 | ExchangeDeposit コントラクトの `Deposit` イベントをフィルタ取得 |
| **RPC メソッド** | `debug_traceBlockByNumber` (debug namespace) | `eth_getBlockByNumber` + `eth_getTransactionReceipt` (eth namespace) | `eth_getLogs` (eth namespace) |
| **ノード要件** | Archive node + debug API 有効 | Full node | Full node |
| **internal TX 検知** | **可能** | **不可能** | **可能** (proxy 経由で Deposit イベント発火) |
| **ERC20 検知** | トレースから検知可能 | 不可能 (別途 eth_getLogs 必要) | Transfer イベント併用 or gatherErc20() |

## 1. なぜ eth_getBlock だけでは不十分なのか

`eth_getBlockByNumber` が返すのはトップレベルのトランザクション（EOA が署名・送信した TX）のみ。以下のケースを検知できない:

### 検知できないケース

| ケース | 具体例 | 影響度 |
|---|---|---|
| **internal transaction** | コントラクトが `call` / `transfer` / `send` で入金アドレスへ ETH 送金 | **高** — DEX aggregator, multisig wallet, スマートコントラクトウォレットからの入金が全て漏れる |
| **ERC20 transfer** | `token.transfer(depositAddr, amount)` | **高** — トップレベルTXの `to` はトークンコントラクトであり、入金先アドレスは TX の `to` に現れない |
| **batch transfer** | Disperse.app 等のバッチ送金コントラクト | **高** — 1 TX で複数アドレスへ送金。TX の `to` はバッチコントラクト |
| **CREATE2 経由の送金** | コントラクトデプロイと同時に ETH を送る | **低** — 稀だが起こりうる |

### internal TX の発生頻度

Ethereum mainnet では全 ETH 移動のうち約 **30-50%** が internal transaction と推定される。Account Abstraction (ERC-4337) やスマートコントラクトウォレット (Safe, Argent 等) の普及でこの割合は増加傾向にある。

**→ eth_getBlock のみの運用では、入金の 30-50% を見落とすリスクがあり、取引所の入金検知としては致命的。** これが多くの取引所が高コストな `debug_trace` を使わざるを得ない理由。

## 2. ExchangeDeposit Proxy がこの問題を解決する仕組み

```
[EOA / コントラクト / Multisig]
         |
         | ETH送金 (top-level でも internal でも)
         v
    Proxy (ユーザー固有アドレス)
         |
         | receive() → CALL ExchangeDeposit
         v
    ExchangeDeposit
         |
         | emit Deposit(proxy_address, amount)
         | forward ETH → coldAddress
         v
    Cold Wallet
```

**ポイント**: Proxy の `receive()` は送金元が EOA でもコントラクトでも等しく発火する。つまり internal TX であっても `Deposit` イベントが発行され、`eth_getLogs` で検知可能。debug_trace が不要になる。

## 3. リクエストあたりのコスト比較 (3方式)

### A: `debug_traceBlockByNumber`

| 項目 | 詳細 |
|---|---|
| **処理** | ブロック内の**全TX**をステップごとにEVM再実行 |
| **メモリ使用** | 全opcodeのトレース結果をメモリ上に構築（callTracer でも全 CALL/CREATE を追跡） |
| **I/O** | 各TXの state trie アクセス（ストレージ読み書きの再現） |
| **レスポンスサイズ** | **5-50MB/ブロック**（TX数・複雑度に依存） |
| **所要時間** | **数百ms〜数十秒/ブロック** |

### B: `eth_getBlockByNumber` (+ getTransactionReceipt)

| 項目 | 詳細 |
|---|---|
| **処理** | ブロックデータの DB ルックアップ。EVM再実行なし |
| **メモリ使用** | ブロック内全TX オブジェクトをシリアライズ |
| **I/O** | ブロック DB + receipt DB へのルックアップ |
| **レスポンスサイズ** | **50KB-500KB/ブロック** (full TX objects) + **各 receipt 1-5KB** |
| **所要時間** | **10-100ms/ブロック** (getBlock) + **各 receipt 5-20ms** |
| **追加リクエスト** | 入金候補 TX の receipt 確認が必要（status=1 の検証）。1ブロックあたり数件〜数十件 |

### C: `eth_getLogs` (ExchangeDeposit Deposit イベント)

| 項目 | 詳細 |
|---|---|
| **処理** | Bloom filter チェック → ログインデックス検索 |
| **メモリ使用** | 該当イベントのみ（通常数件〜数十件/ブロック） |
| **I/O** | ログインデックスへの軽量クエリ |
| **レスポンスサイズ** | **0.5-5KB/ブロック** |
| **所要時間** | **3-30ms/ブロック** |
| **追加リクエスト** | なし（イベントが発火 = 入金成功。revert された TX からはイベントが出ない） |

## 4. チェーン別 3方式比較

### Ethereum

| 指標 | A: debug_trace | B: eth_getBlock | C: eth_getLogs |
|---|---|---|---|
| ブロック間隔 | 12秒 | 12秒 | 12秒 |
| 平均TX数/ブロック | ~150-200 | ~150-200 | - |
| リクエスト処理時間 | 2-15秒 | 50-200ms (*1) | 5-30ms |
| レスポンスサイズ/ブロック | 5-50MB | 100-500KB (*1) | 0.5-5KB |
| internal TX 検知 | **全件** | **不可** | **全件** |
| ノード要件 | Archive + Debug | Full node | Full node |
| 月間コスト (SaaS) | $500-3,000 | $100-400 | $0-200 |

*1: getBlock + 監視対象 TX の getTransactionReceipt の合計

### Polygon

| 指標 | A: debug_trace | B: eth_getBlock | C: eth_getLogs |
|---|---|---|---|
| ブロック間隔 | 2秒 | 2秒 | 2秒 |
| 平均TX数/ブロック | ~50-100 | ~50-100 | - |
| リクエスト処理時間 | 1-8秒 | 30-150ms | 3-20ms |
| レスポンスサイズ/ブロック | 2-20MB | 30-200KB | 0.3-3KB |
| 月間リクエスト数 | 1,296,000 | 1,296,000 + receipt分 | ~12,960 (レンジ100) |
| internal TX 検知 | **全件** | **不可** | **全件** |

### Avalanche (C-Chain)

| 指標 | A: debug_trace | B: eth_getBlock | C: eth_getLogs |
|---|---|---|---|
| ブロック間隔 | 2秒 | 2秒 | 2秒 |
| 平均TX数/ブロック | ~5-30 | ~5-30 | - |
| リクエスト処理時間 | 0.5-5秒 | 20-80ms | 2-15ms |
| レスポンスサイズ/ブロック | 1-10MB | 10-100KB | 0.2-2KB |
| internal TX 検知 | **全件** | **不可** | **全件** |
| 備考 | debug API 対応プロバイダ少 | 全プロバイダ対応 | 全プロバイダ対応 |

### Flare

| 指標 | A: debug_trace | B: eth_getBlock | C: eth_getLogs |
|---|---|---|---|
| ブロック間隔 | ~1.8秒 | ~1.8秒 | ~1.8秒 |
| 平均TX数/ブロック | ~5-20 | ~5-20 | - |
| リクエスト処理時間 | 0.5-3秒 | 15-60ms | 2-10ms |
| レスポンスサイズ/ブロック | 0.5-5MB | 5-50KB | 0.1-1KB |
| internal TX 検知 | **全件** | **不可** | **全件** |
| 備考 | debug API 対応プロバイダ極少 | 全プロバイダ対応 | 全プロバイダ対応 |

## 5. 全4チェーン合計の月間コスト概算 (3方式)

### リクエスト量

| チェーン | ブロック/月 | A: debug_trace | B: eth_getBlock (*2) | C: eth_getLogs (レンジ100) |
|---|---|---|---|---|
| Ethereum | ~216,000 | 216,000 | ~260,000 | ~2,160 |
| Polygon | ~1,296,000 | 1,296,000 | ~1,550,000 | ~12,960 |
| Avalanche | ~1,296,000 | 1,296,000 | ~1,400,000 | ~12,960 |
| Flare | ~1,440,000 | 1,440,000 | ~1,550,000 | ~14,400 |
| **合計** | | **4,248,000** | **~4,760,000** | **~42,480** |

*2: getBlock + 入金候補 TX の getTransactionReceipt (ブロックあたり平均 0.2-0.5 件と仮定)

### データ転送量 (月間)

| チェーン | A: debug_trace | B: eth_getBlock | C: eth_getLogs |
|---|---|---|---|
| Ethereum | 2-10 TB | 20-100 GB | 1-10 GB |
| Polygon | 3-25 TB | 40-250 GB | 0.5-5 GB |
| Avalanche | 1-12 TB | 12-130 GB | 0.3-3 GB |
| Flare | 0.7-7 TB | 7-70 GB | 0.2-2 GB |
| **合計** | **~7-54 TB** | **~80-550 GB** | **~2-20 GB** |

### ノード CPU/メモリ負荷

| | A: debug_trace | B: eth_getBlock | C: eth_getLogs |
|---|---|---|---|
| CPU | EVM全TX再実行 → **常時高負荷** | DBルックアップ → **低〜中** | Bloom filter + index → **極低** |
| メモリ | トレースバッファリング → **数GB** | TXオブジェクト → **数十〜数百MB** | イベントデータ → **数MB** |
| ディスクI/O | state trie ランダムリード → **集中** | ブロックDB シーケンシャル → **中** | ログindex → **軽微** |
| 同時処理 | 1ノードで2-3チェーンが限界 | 1ノードで5-10チェーン | 1ノードで数十チェーン |

## 6. SaaS プロバイダ利用時のコスト比較

| プロバイダ | A: debug_trace (月額) | B: eth_getBlock (月額) | C: eth_getLogs (月額) |
|---|---|---|---|
| Alchemy | $500-2,000 | $100-400 | $0-100 |
| Infura | $500-1,500 | $100-300 | $0-50 |
| QuickNode | $300-1,500 | $50-300 | $0-50 |

- A: debug/trace API は上位プランまたは有料アドオンが必要
- B: 標準 API だがリクエスト量が多く中位プランが必要
- C: 標準 API かつリクエスト量が極少。Free tier で収まる可能性あり

## 7. 3方式の総合比較

| 評価軸 | A: debug_trace | B: eth_getBlock | C: eth_getLogs (ExchangeDeposit) |
|---|---|---|---|
| **検知精度** | ★★★ 完全 | ★☆☆ internal TX 漏れ | ★★★ 完全 (proxy 経由) |
| **ノードコスト** | ★☆☆ 最も高い | ★★☆ 中程度 | ★★★ 最も安い |
| **帯域消費** | ★☆☆ 数十TB/月 | ★★☆ 数百GB/月 | ★★★ 数十GB/月 |
| **CPU負荷** | ★☆☆ EVM再実行 | ★★☆ DBルックアップ | ★★★ インデックスのみ |
| **レイテンシ** | ★☆☆ 秒単位 | ★★☆ 百ms単位 | ★★★ ms単位 |
| **ノード要件** | ★☆☆ Archive + debug | ★★★ Full node | ★★★ Full node |
| **プロバイダ対応** | ★☆☆ 限定的 | ★★★ 全プロバイダ | ★★★ 全プロバイダ |
| **実装の複雑さ** | ★★☆ トレース解析が複雑 | ★★★ 最もシンプル | ★★☆ コントラクトデプロイ＋移行が必要 |
| **リアルタイム対応** | ★☆☆ ポーリングのみ | ★★☆ ポーリング | ★★★ WebSocket subscribe 可 |

## 8. 考察: なぜ eth_getBlock ではなく ExchangeDeposit なのか

### eth_getBlock は「安かろう悪かろう」

eth_getBlock はコストだけ見れば debug_trace より大幅に安い（帯域 1/100、CPU負荷 1/10 程度）。しかし **internal TX を検知できない** という致命的な欠陥がある。

現実的にはこの欠陥を以下のように補填することになり、結局コストが膨らむ:

1. **ERC20 検知のために eth_getLogs を併用** → リクエスト追加
2. **internal TX 検知のために debug_trace を併用** → 結局 debug API が必要に
3. **残高ポーリングで補完** → 各入金アドレスの `eth_getBalance` を定期実行 → アドレス数 × ポーリング頻度のリクエスト爆発

つまり eth_getBlock 単体は取引所の入金検知には使えず、他の手法と組み合わせた「ハイブリッド」にならざるを得ない。その結果、システムの複雑性とコストの両方が増大する。

### ExchangeDeposit は「安くて正確」

ExchangeDeposit Proxy は以下を同時に達成する:

- **internal TX も含めた完全な検知** (debug_trace と同等の精度)
- **eth_getLogs のみの最小コスト** (debug_trace の 1/1000 以下の帯域)
- **シンプルな実装** (1つの RPC メソッド、1つのイベントトピック)

唯一のトレードオフは初期のコントラクトデプロイコストとアドレス移行だが、運用コストの削減で早期に回収できる。

### コスト削減の段階的整理

```
                        検知精度    月間帯域     月間コスト(SaaS)
                        --------   ---------   ---------------
A: debug_trace          100%       7-54 TB     $1,500-6,000
B: eth_getBlock のみ     50-70%     80-550 GB   $250-1,200
B': eth_getBlock+補完    ~90%       200GB-2TB   $500-2,500
C: ExchangeDeposit      100%       2-20 GB     $0-400
```

B' (eth_getBlock + 残高ポーリング等の補完) でも internal TX の一部は検知漏れが残り、検知精度 100% にはならない。ExchangeDeposit (C) は A と同じ 100% の精度を、A の 1/1000 以下のコストで実現する。

## 9. 移行時の注意点

| 課題 | 対策 |
|---|---|
| **ERC20 入金の検知** | `Deposit` イベントは ETH 送金時のみ発火。ERC20 は `Transfer` イベントを proxy アドレス宛にフィルタするか、定期的に `gatherErc20()` を呼ぶバッチ処理が必要 |
| **既存アドレスの移行** | 既にユーザーに配布済みの入金アドレスは proxy ではないため、新しい proxy アドレスを発行する移行期間が必要 |
| **コントラクトデプロイコスト** | ProxyFactory 経由で 1 proxy あたり約 60,000-80,000 gas。ユーザー数 × ガス代の初期投資 |
| **チェーンごとのデプロイ** | 4チェーンそれぞれに ExchangeDeposit + ProxyFactory をデプロイする必要がある |
| **移行期間の並行運用** | 旧アドレス (debug_trace) と新アドレス (eth_getLogs) の両方を一定期間監視する必要がある |

## 10. まとめ

| 指標 | A → C 削減率 | B → C 削減率 | B の精度リスク |
|---|---|---|---|
| リクエスト数 | **~99%** | **~99%** | - |
| データ転送量 | **~99.9%** | **~95%** | - |
| CPU/メモリ負荷 | **~95-99%** | **~80-90%** | - |
| ノード運用コスト (SaaS) | **~90-100%** | **~70-90%** | - |
| 入金検知精度 | 同等 (100%) | **大幅改善** | eth_getBlock は 50-70% |
| ノード要件 | Archive → Full | 同等 (Full) | - |

**結論**: eth_getBlock は debug_trace よりコストは低いが、internal TX を検知できないため取引所の入金検知としては不完全。ExchangeDeposit Proxy への移行は、debug_trace と同等の検知精度を維持しながらコストを桁違いに削減する唯一の方法であり、eth_getBlock を選択する合理的な理由はない。
