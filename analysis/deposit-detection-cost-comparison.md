# 入金検知方式の総合比較分析

## debug_trace vs eth_getBlock vs ExchangeDeposit Proxy vs EIP-7702

対象チェーン: Ethereum, Polygon, Avalanche, Flare

---

## 1. 4つのアプローチの概要

| | A: `debug_traceBlockByNumber` | B: `eth_getBlockByNumber` | C: ExchangeDeposit Proxy | D: EIP-7702 + ExchangeDeposit |
|---|---|---|---|---|
| **原理** | ブロック内全TXをEVM再実行し internal call を含む全送金をトレース | ブロック内のトップレベルTXのみ取得 | Proxy コントラクト経由で `Deposit` イベントを発火 | 既存 EOA にコントラクトコードを委任し Proxy と同等動作 |
| **RPC メソッド** | `debug_traceBlockByNumber` | `eth_getBlockByNumber` + `eth_getTransactionReceipt` | `eth_getLogs` | `eth_getLogs` |
| **ノード要件** | Archive node + debug API | Full node | Full node | Full node |
| **internal TX 検知** | 可能 | **不可能** | 可能 | 可能 |
| **入金アドレス** | 既存 EOA | 既存 EOA | **新規コントラクトアドレス** | **既存 EOA をそのまま使用** |
| **チェーン要件** | なし | なし | なし | **Pectra upgrade 必須** |

---

## 2. なぜ eth_getBlock だけでは不十分なのか

`eth_getBlockByNumber` が返すのはトップレベルのトランザクション（EOA が署名・送信した TX）のみ。以下のケースを検知できない:

| ケース | 具体例 | 影響度 |
|---|---|---|
| **internal transaction** | コントラクトが `call` / `transfer` / `send` で入金アドレスへ ETH 送金 | **高** — DEX aggregator, multisig wallet, スマートコントラクトウォレットからの入金が全て漏れる |
| **ERC20 transfer** | `token.transfer(depositAddr, amount)` | **高** — トップレベルTXの `to` はトークンコントラクトであり、入金先アドレスは TX の `to` に現れない |
| **batch transfer** | Disperse.app 等のバッチ送金コントラクト | **高** — 1 TX で複数アドレスへ送金。TX の `to` はバッチコントラクト |

Ethereum mainnet 上の ETH value transfer のうち、internal transaction が占める割合は無視できない規模にある（正確な比率はブロックや時期により大きく変動する）。Account Abstraction (ERC-4337) やスマートコントラクトウォレット (Safe, Argent 等) の普及に伴い、コントラクト経由の送金は増加傾向にある。

取引所入金に限れば、多くのユーザーは EOA から直接送金するため internal TX の比率はネットワーク全体より低い可能性がある。しかし、DEX aggregator やスマートウォレット経由の入金は internal TX となるため、**見落としをゼロにできないこと自体が取引所にとって問題**となる。

補完策を組み合わせても完全にはならない:

1. **ERC20 検知のために eth_getLogs を併用** → リクエスト追加
2. **internal TX 検知のために debug_trace を併用** → 結局 debug API が必要に
3. **残高ポーリングで補完** → 各入金アドレスの `eth_getBalance` を定期実行 → アドレス数 × ポーリング頻度でリクエスト数が増大

---

## 3. ExchangeDeposit が internal TX を検知できる仕組み

```
[EOA / コントラクト / Multisig / DEX aggregator]
         |
         | ETH送金 (top-level でも internal でも)
         v
    Proxy or delegated EOA
         |
         | receive() → CALL ExchangeDeposit
         v
    ExchangeDeposit 本体
         |
         | emit Deposit(proxy_or_eoa_address, amount)
         | forward ETH → coldAddress
         v
    Cold Wallet
```

Proxy / delegated EOA の `receive()` は送金元が EOA でもコントラクトでも等しく発火する。internal TX でも `Deposit` イベントが発行され、`eth_getLogs` で検知可能。

---

## 4. リクエストあたりのコスト比較

### A: `debug_traceBlockByNumber`

| 項目 | 詳細 |
|---|---|
| **処理** | ブロック内の**全TX**をEVM再実行（callTracer の場合は CALL レベル、struct tracer の場合は opcode レベル） |
| **メモリ使用** | トレース結果をメモリ上に構築（tracer の種類で大きく異なる） |
| **I/O** | 各TXの state trie アクセス（ストレージ読み書きの再現） |
| **レスポンスサイズ** | **5-50MB/ブロック** |
| **所要時間** | **数百ms〜数十秒/ブロック** |

### B: `eth_getBlockByNumber` (+ getTransactionReceipt)

| 項目 | 詳細 |
|---|---|
| **処理** | ブロックデータの DB ルックアップ。EVM再実行なし |
| **メモリ使用** | ブロック内全TX オブジェクトをシリアライズ |
| **I/O** | ブロック DB + receipt DB へのルックアップ |
| **レスポンスサイズ** | **50KB-500KB/ブロック** + **各 receipt 1-5KB** |
| **所要時間** | **10-100ms/ブロック** + **各 receipt 5-20ms** |

### C / D: `eth_getLogs` (ExchangeDeposit Deposit イベント)

| 項目 | 詳細 |
|---|---|
| **処理** | Bloom filter チェック → ログインデックス検索 |
| **メモリ使用** | 該当イベントのみ |
| **I/O** | ログインデックスへの軽量クエリ |
| **レスポンスサイズ** | **0.5-5KB/ブロック** |
| **所要時間** | **3-30ms/ブロック** |

C (Proxy) と D (EIP-7702) は入金検知の RPC コストは同一。違いはオンチェーンのセットアップ方法のみ。

---

## 5. チェーン別比較

### Ethereum

| 指標 | A: debug_trace | B: eth_getBlock | C/D: eth_getLogs |
|---|---|---|---|
| ブロック間隔 | 12秒 | 12秒 | 12秒 |
| 平均TX数/ブロック | ~150-200 | ~150-200 | - |
| リクエスト処理時間 | 2-15秒 | 50-200ms | 5-30ms |
| レスポンスサイズ/ブロック | 5-50MB | 100-500KB | 0.5-5KB |
| internal TX 検知 | **全件** | **不可** | **全件** |
| ノード要件 | Archive + Debug | Full node | Full node |

### Polygon

| 指標 | A: debug_trace | B: eth_getBlock | C/D: eth_getLogs |
|---|---|---|---|
| ブロック間隔 | 2秒 | 2秒 | 2秒 |
| 平均TX数/ブロック | ~50-100 | ~50-100 | - |
| リクエスト処理時間 | 1-8秒 | 30-150ms | 3-20ms |
| レスポンスサイズ/ブロック | 2-20MB | 30-200KB | 0.3-3KB |
| 月間リクエスト数 | 1,296,000 | 1,296,000 + receipt分 | ~12,960 (レンジ100) |

### Avalanche (C-Chain)

| 指標 | A: debug_trace | B: eth_getBlock | C/D: eth_getLogs |
|---|---|---|---|
| ブロック間隔 | 2秒 | 2秒 | 2秒 |
| リクエスト処理時間 | 0.5-5秒 | 20-80ms | 2-15ms |
| レスポンスサイズ/ブロック | 1-10MB | 10-100KB | 0.2-2KB |
| 備考 | debug API 対応プロバイダ少 | 全プロバイダ対応 | 全プロバイダ対応 |

### Flare

| 指標 | A: debug_trace | B: eth_getBlock | C/D: eth_getLogs |
|---|---|---|---|
| ブロック間隔 | ~1.8秒 | ~1.8秒 | ~1.8秒 |
| リクエスト処理時間 | 0.5-3秒 | 15-60ms | 2-10ms |
| レスポンスサイズ/ブロック | 0.5-5MB | 5-50KB | 0.1-1KB |
| 備考 | debug API 対応プロバイダ極少 | 全プロバイダ対応 | 全プロバイダ対応 |

---

## 6. 全4チェーン合計の月間コスト概算

### リクエスト量 (月間)

| チェーン | ブロック/月 | A: debug_trace | B: eth_getBlock (*1) | C/D: eth_getLogs (レンジ100) |
|---|---|---|---|---|
| Ethereum | ~216,000 | 216,000 | ~260,000 | ~2,160 |
| Polygon | ~1,296,000 | 1,296,000 | ~1,550,000 | ~12,960 |
| Avalanche | ~1,296,000 | 1,296,000 | ~1,400,000 | ~12,960 |
| Flare | ~1,440,000 | 1,440,000 | ~1,550,000 | ~14,400 |
| **合計** | | **4,248,000** | **~4,760,000** | **~42,480** |

*1: getBlock + 入金候補 TX の getTransactionReceipt

### データ転送量 (月間、概算)

ブロックあたりのレスポンスサイズ × ブロック数から算出した概算。実際の値は TX 数・複雑度・tracer 設定・入金件数により変動する。

| チェーン | A: debug_trace | B: eth_getBlock | C/D: eth_getLogs |
|---|---|---|---|
| Ethereum | TB オーダー | 数十〜数百 GB | 数 GB |
| Polygon | TB オーダー | 数十〜数百 GB | 数 GB |
| Avalanche | 数百 GB〜TB | 数十 GB | 数百 MB〜数 GB |
| Flare | 数百 GB〜TB | 数 GB〜数十 GB | 数百 MB〜数 GB |

**方式間のオーダーの差**: A は TB 級、B は数十〜数百 GB 級、C/D は GB 級。A → C/D で 2-3 桁の削減。

### ノード CPU/メモリ負荷

| | A: debug_trace | B: eth_getBlock | C/D: eth_getLogs |
|---|---|---|---|
| CPU | EVM全TX再実行 → **常時高負荷** | DBルックアップ → **低〜中** | Bloom filter + index → **極低** |
| メモリ | トレースバッファリング → **数GB** | TXオブジェクト → **数十〜数百MB** | イベントデータ → **数MB** |
| ディスクI/O | state trie ランダムリード → **集中** | ブロックDB シーケンシャル → **中** | ログindex → **軽微** |
| 監視の同時処理 | trace の処理待ちがボトルネック | ブロック取得が主な負荷 | 監視ロジック側の負荷はほぼゼロ |

### SaaS プロバイダ利用時の傾向

具体的な金額はプラン・利用量・チェーン数に依存するため省略するが、定性的な傾向は以下の通り:

- **A (debug_trace)**: debug/trace API は多くのプロバイダで上位プランまたは有料アドオンが必要
- **B (eth_getBlock)**: 標準 API だがリクエスト量が多く、無料枠では収まりにくい
- **C/D (eth_getLogs)**: 標準 API かつレンジクエリでリクエスト数を大幅に削減できるため、最も安価。無料枠で収まる可能性もある

---

## 7. C (Proxy) vs D (EIP-7702): オンチェーンセットアップの比較

C と D は入金検知の RPC コスト（eth_getLogs）は同一。違いはオンチェーン側のセットアップとトレードオフにある。

### Sepolia テストネットでの検証結果（EIP-7702）

| 検証項目 | 結果 | 備考 |
|---|---|---|
| 既存 EOA → Proxy に delegate → Deposit イベント発火 | **✅ 成功** | [TX](https://sepolia.etherscan.io/tx/0x913f068e57e02cd5bd3638456b3ed31295879b678a8b7c9fbe708b6265541e2d) |
| イベント集約 (eth_getLogs で一括監視) | **✅ 成功** | [TX](https://sepolia.etherscan.io/tx/0xddf3afa2ad2f7f76dc7536039871012ddf97fd8f808f6c60ac900db0704c4ad5) |
| バッチ delegation (1TX で複数 EOA) | **✅ 成功** | Forge Script 使用 [TX](https://sepolia.etherscan.io/tx/0x9f00d9c6c922c76f1851d81c0ef609a727984213a46105c83143f3891701edd1) |
| delegation chain (EOA → EOA → Contract) | **❌ 失敗** | `0xef` opcode エラーで revert |
| ExchangeDeposit 本体に直接 delegate | **❌ 失敗** | EOA の storage が空で `coldAddress == address(0)` → revert |
| delegated EOA で gatherEth() | **✅ 成功** | [TX](https://sepolia.etherscan.io/tx/0xa0fa1a37f21954ee15c56508d6f24ad1aceb080f54b155dc46bd59cc06ae64c0) |
| receive() 回避 (delegation 設定時) | **✅ 成功** | to=coldAddress or address(0) で回避 |

### セットアップコスト比較

| | C: Proxy (CREATE2) | D: EIP-7702 delegation |
|---|---|---|
| **1アドレスあたりの gas** | ~60,000-80,000 (Proxy デプロイ) | ~25,000 (delegation 設定) |
| **バッチ処理** | 1TX で 1 Proxy | **1TX で複数 EOA を一括 delegate** |
| **秘密鍵の要否** | 不要 (Factory が CREATE2) | **必要** (各 EOA の秘密鍵で authorization 署名) |
| **既存アドレスの継続利用** | **不可** (新規コントラクトアドレス) | **可能** (EOA アドレスそのまま) |
| **解除可能性** | 不可 (デプロイ済みコントラクト) | **可能** (address(0) に再 delegate) |

### ガスコスト試算: 10万ユーザー × 4チェーン

USD 換算は参考値。トークン価格・ガス代は変動するため、実際のコストは大きく異なりうる。

| チェーン | C: Proxy デプロイ (70,000 gas) | D: EIP-7702 delegation (25,000 gas) | gas 削減率 |
|---|---|---|---|
| Ethereum (30 gwei) | 210 ETH | 75 ETH | 64% |
| Polygon (50 gwei) | 350 MATIC | 125 MATIC | 64% |
| Avalanche (30 nAVAX) | 210 AVAX | 75 AVAX | 64% |
| Flare (100 gwei) | 700 FLR | 250 FLR | 64% |

Ethereum のコストが支配的。Polygon / Flare はほぼ無視できるレベル。Avalanche は Ethereum と比べれば小さいが、AVAX の価格次第では一定のコストになる。

---

## 8. 各方式の Pros / Cons

### A: debug_traceBlockByNumber

| Pros | Cons |
|---|---|
| 既存 EOA をそのまま使える。追加コントラクト不要 | **ノードコストが最も高い** (Archive node + debug API) |
| internal TX を含む完全な検知 | **帯域消費が膨大** (月間 TB オーダー) |
| 実装が成熟しており実績がある | debug API 対応プロバイダが限定的 (特に Avalanche/Flare) |
| | **レイテンシが秒単位** でリアルタイム性に欠ける |
| | トレース解析ロジックが複雑 |

### B: eth_getBlockByNumber

| Pros | Cons |
|---|---|
| 最も実装がシンプル | **internal TX を検知できない** (コントラクト経由の入金を見落とす) |
| Full node で運用可能 | ERC20 検知には結局 eth_getLogs が必要 |
| 全プロバイダ対応 | 補完策を組み合わせるとシステム複雑度・コストが増大 |
| debug_trace 比でコスト約 1/10 | 単独では網羅的な入金検知には不十分。残高ポーリング等の補完が必要 |

### C: ExchangeDeposit Proxy (CREATE2)

| Pros | Cons |
|---|---|
| **internal TX も含め完全検知** (debug_trace 同等) | **ユーザーの入金アドレスが変わる** (新規コントラクトアドレス) |
| **eth_getLogs のみで完結** (debug_trace 比で帯域 2-3 桁削減) | Proxy デプロイにガス代がかかる (Ethereum で 0.0021 ETH/ユーザー @30gwei) |
| Archive node 不要 (Full node で運用可) | 既存ユーザーへの移行期間が必要 |
| 入金と同時に coldAddress へ自動転送 (sweep TX 不要) | コントラクトアドレスへの送金を拒否するウォレットが一部ある |
| minimumInput によるダストアタック防御 | ERC20 は自動検知されない (gatherErc20() の定期実行が必要) |
| WebSocket (`eth_subscribe`) でリアルタイム検知可能 | コントラクト監査コスト |
| ユーザー数が増えても RPC コストが増えない | |
| Pectra 非対応チェーンでも使える | |

### D: EIP-7702 + ExchangeDeposit

| Pros | Cons |
|---|---|
| **既存 EOA アドレスをそのまま使える** (移行不要) | **Pectra upgrade が必須** (未対応チェーンでは使えない) |
| Proxy 方式と同じ完全検知 + 低コスト eth_getLogs | **各 EOA の秘密鍵で authorization 署名が必要** |
| delegation gas が Proxy デプロイの ~1/3 (~25,000 vs ~70,000) | 署名サーバへの EIP-7702 対応実装が必要 |
| **1TX で複数 EOA をバッチ delegate** 可能 | `cast` 単体では非対応。Forge Script or 専用ツールが必要 |
| delegation 解除が可能 (柔軟性) | 鍵漏洩時に第三者が **別コントラクトへ再 delegate（入金先の乗っ取り）** するリスク |
| minimumInput によるダストアタック防御 | delegation chain 不可 (EOA → EOA → Contract は失敗) |
| EOA なのでどのウォレットからも送金可能 | ExchangeDeposit 本体への直接 delegate 不可 (Proxy 経由必須) |
| | ERC20 は C と同様に gatherErc20() が必要 |

---

## 9. ガス代の負担モデル

### 誰がガス代を負担するか

C (Proxy デプロイ) / D (EIP-7702 delegation) のいずれも、ユーザーのアドレスをセットアップするためのオンチェーンコストが発生する。

| 方式 | Ethereum (30 gwei, 1ユーザーあたり) | Polygon/Avalanche/Flare |
|---|---|---|
| C: Proxy デプロイ | 0.0021 ETH (70,000 gas) | 無視できるレベル |
| D: EIP-7702 delegation | 0.00075 ETH (25,000 gas) | 無視できるレベル |

### 負担方式の比較

| 方式 | メリット | デメリット |
|---|---|---|
| **取引所が全額負担** | UX 最良。競合優位性 | Ethereum では初期投資が大きい (C: 210 ETH, D: 75 ETH @10万ユーザー) |
| **初回入金から差し引き** | 追加手続き不要。ユーザー意識低い | 少額入金だとデプロイ gas > 入金額になりうる。最低入金額の引き上げが必要 |
| **アカウント開設手数料** | 前払いで未使用アドレスの無駄なコストを回避 | 新規ユーザーの障壁。競合との差別化で不利 |
| **入金手数料に上乗せ** | 長期で薄く回収。ユーザーの抵抗感が少ない | 回収に時間がかかる。入金頻度が低いユーザーは元が取れない |
| **lazy deploy** | 初回入金時にのみセットアップ。未使用アドレスの無駄を回避 | 初回入金のレイテンシ増加 (数秒〜数十秒) |

### チェーン別の現実的判断

| チェーン | ガス代/ユーザー (C) | ガス代/ユーザー (D) | 推奨 |
|---|---|---|---|
| **Ethereum** | 0.0021 ETH | 0.00075 ETH | 初回入金差し引き or lazy deploy。全額負担は資金力次第 |
| **Polygon** | 極小 | 極小 | **取引所全額負担** |
| **Avalanche** | 極小 | 極小 | **取引所全額負担** |
| **Flare** | 極小 | 極小 | **取引所全額負担** |

Ethereum 以外のチェーンではガス代が極めて低く、ユーザーへの転嫁を検討する必要はない。Ethereum のみ、負担方式の設計が必要。

### 損益分岐分析 (取引所全額負担の場合)

```
前提: 10万ユーザー、Ethereum (30 gwei)

初期コスト (1回限り、Ethereum のみ):
  C (Proxy):     210 ETH
  D (EIP-7702):  75 ETH

月間運用コスト削減:

  (1) RPC / ノードコスト削減
    SaaS の場合、debug_trace 向けプラン → 標準プランへの差額
    チェーン数・プロバイダにより異なるため一概に言えないが、
    debug/trace API は上位プランが必要なケースが多い

  (2) sweep TX の廃止
    現行: 各 EOA から個別に ETH を回収 (21,000 gas/TX)
    ExchangeDeposit: 入金時に自動で coldAddress へ転送。sweep 不要
    月1回 sweep する場合 (30 gwei):
      全ユーザー: 100,000 × 21,000 gas × 30 gwei = 63 ETH/回
      アクティブ率 10%: 10,000 × 21,000 gas × 30 gwei = 6.3 ETH/回

損益分岐の目安 (sweep 削減のみ、アクティブ率 10%):
  C: 210 ETH / 6.3 ETH/月 ≈ 33 ヶ月
  D:  75 ETH / 6.3 ETH/月 ≈ 12 ヶ月

※ アクティブ率・ガス代・sweep 頻度により大きく変動する
※ RPC コスト削減・運用工数削減を加味すると回収は早まる
※ lazy deploy の場合は初期コストが分散される
※ Ethereum 以外のチェーンのデプロイコスト・sweep コストは無視できるレベル
```

---

## 10. 4方式の総合スコア

| 評価軸 | A: debug_trace | B: eth_getBlock | C: ED Proxy | D: EIP-7702 + ED |
|---|---|---|---|---|
| **ETH検知精度** | ★★★ | ★★☆ (*2) | ★★★ | ★★★ |
| **RPC コスト** | ★☆☆ | ★★☆ | ★★★ | ★★★ |
| **帯域消費** | ★☆☆ | ★★☆ | ★★★ | ★★★ |
| **CPU負荷** | ★☆☆ | ★★☆ | ★★★ | ★★★ |
| **レイテンシ** | ★☆☆ | ★★☆ | ★★★ | ★★★ |
| **ノード要件** | ★☆☆ | ★★★ | ★★★ | ★★★ |
| **プロバイダ対応** | ★☆☆ | ★★★ | ★★★ | ★★★ |
| **アドレス継続利用** | ★★★ | ★★★ | ★☆☆ | ★★★ |
| **セットアップ gas** | ★★★ | ★★★ | ★★☆ | ★★☆ |
| **秘密鍵の要否** | ★★☆ | ★★☆ | ★★★ | ★☆☆ |
| **チェーン対応幅** | ★★☆ | ★★★ | ★★★ | ★☆☆ |
| **ダストアタック耐性** | ★☆☆ | ★☆☆ | ★★★ | ★★★ |
| **sweep TX 不要** | ★☆☆ | ★☆☆ | ★★★ | ★★★ |
| **実装の成熟度** | ★★★ | ★★★ | ★★☆ | ★☆☆ |

*2: トップレベル TX のみ検知可能。internal TX (コントラクト経由の ETH 送金) は検知不可

---

## 11. 推奨戦略

### 短期: C — ExchangeDeposit Proxy

- Pectra 対応の有無に依存せず、全チェーンで導入可能
- internal TX 検知 + eth_getLogs による低コスト運用
- Polygon / Avalanche / Flare ではデプロイコストがほぼゼロ
- Ethereum は lazy deploy or 初回入金差し引きでガス代を管理
- ただし既存ユーザーにはアドレス変更を伴う移行が必要

### 中長期 (Pectra 普及後): D — EIP-7702 + ExchangeDeposit

- 既存 EOA アドレスをそのまま使えるためアドレス移行が不要
- delegation gas が Proxy デプロイの約 1/3
- バッチ delegation で既存 EOA を一括変換可能
- ただし各 EOA の秘密鍵で authorization 署名が必要なため、署名基盤の整備が前提
- Pectra 対応時期はチェーンにより異なるため、対応済みチェーンから順次移行

### ハイブリッド運用

```
                    Pectra 未対応チェーン → C: Proxy (CREATE2)
                   /
全チェーン共通 ──── eth_getLogs で入金検知
                   \
                    Pectra 対応済みチェーン → D: EIP-7702 delegation
                    (新規ユーザーは D, 既存 Proxy ユーザーはそのまま C)
```

C と D は入金検知側 (eth_getLogs) が完全に同一のため、バックエンドの入金検知ロジックは 1 つで済む。オンチェーン側のセットアップ方式だけがチェーンの Pectra 対応状況で分岐する。

---

## 12. まとめ

```
                    検知精度    月間帯域        既存EOA継続  チェーン要件
                    --------   -----------    ----------  ----------
A: debug_trace      完全       TB級            ○          Archive+debug
B: eth_getBlock     不完全(*1) 数十〜数百GB級   ○          Full node
C: ED Proxy         完全       GB級            ×          Full node
D: EIP-7702 + ED    完全       GB級            ○          Full node + Pectra
```

*1: internal TX (コントラクト経由の入金) を検知できない。見落とし率はユーザーの送金手段に依存

- **B (eth_getBlock) は安いが不完全**。internal TX の見落としを許容できない場合、単独では使えない
- **C (Proxy) と D (EIP-7702) は A と同等の精度を、大幅に低い RPC コストで実現**。加えて sweep TX の廃止による gas 削減も見込める
- **D は C より有利な点が多い** (既存アドレス継続 + gas 約 64% 削減) が、Pectra 依存・秘密鍵での authorization 署名が必要という制約がある
- 現実的には **C で導入 → Pectra 普及後に D へ段階移行** が有力な選択肢
