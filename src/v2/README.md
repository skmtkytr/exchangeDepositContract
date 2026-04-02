# ExchangeDeposit v2

v1 のセキュリティレビューを踏まえ、最新の Solidity / OpenZeppelin で再設計したコントラクト群。

## ファイル構成

```
src/v2/
├── ExchangeDepositV2.sol   # メインコントラクト (Ownable2Step + Pausable + ReentrancyGuard)
├── DepositFactoryV2.sol    # Proxy ファクトリ (CREATE2, onlyOwner, batch deploy)
└── README.md               # このファイル
```

## v1 → v2 主な変更点

| 項目 | v1 | v2 |
|------|-----|-----|
| Solidity | 0.6.11 | ^0.8.24 |
| OpenZeppelin | 3.2.0 (`node_modules`) | 5.2.0 (`lib/openzeppelin-contracts`) |
| Admin 管理 | `adminAddress` immutable | `Ownable2Step` (2段階移譲) |
| 停止/復帰 | `kill()` 不可逆 | `Pausable` (pause/unpause) |
| Reentrancy 防御 | なし | `ReentrancyGuard` |
| エラー形式 | 文字列 revert | Custom errors (低ガス) |
| fallback return data | 破棄される | assembly で正しく返す |
| 状態変更イベント | なし | `ColdAddressChanged` 等 |
| Factory アクセス制御 | なし (DoS 可能) | `onlyOwner` |
| バッチデプロイ | なし | `deployBatch()` |
| アドレス予測 | オフチェーンのみ | `predictAddress()` オンチェーン提供 |
| Proxy バイトコード | 74byte カスタム | 同じ (OZ Clones は CALL 経路がなく不適) |

## 環境構築

### 前提

- Node.js (npm) — v1 の依存関係用
- Foundry (forge) — v2 のビルド・テスト用

### セットアップ手順

```bash
# 1. npm 依存インストール (v1 の OZ 3.2.0 等)
npm install

# 2. OZ 5.2.0 を forge でインストール (lib/openzeppelin-contracts に配置)
forge install OpenZeppelin/openzeppelin-contracts@v5.2.0

# 3. ビルド確認
forge build
```

### リマッピング

`foundry.toml` で以下のようにマッピングされている:

- v1 コントラクト (`contracts/`): `@openzeppelin/` → `node_modules/@openzeppelin/` (OZ 3.2.0)
- v2 コントラクト (`src/v2/`): `openzeppelin-contracts/` → `lib/openzeppelin-contracts/` (OZ 5.2.0)

v1 と v2 で異なるバージョンの OZ を import パスで共存させている。

## ビルド

```bash
# v2 コントラクト含む全体をコンパイル
forge build

# v1 コントラクトのみ (Hardhat)
npm run build
```

## テスト

```bash
# v1 テスト (Hardhat/Truffle)
npm test

# Foundry テスト (v2 テストを追加したらこちらで実行)
forge test
```

## v1 セキュリティレビューで見つかった問題と v2 での対応

### Medium

1. **fallback の return data 欠落** → v2 では assembly で `returndatacopy` + `return` を実装
2. **implementation による任意コード実行リスク** → Ownable2Step + マルチシグ推奨で緩和
3. **直接送金による偽 Deposit イベント** → バックエンドで Proxy アドレスとの照合を必須化 (コメントで明記)

### Low

4. **gather のアクセス制御なし** → 設計上維持 (送金先は常に coldAddress/owner)
5. **minimumInput=0 設定可能** → 設計上維持 (admin の意図的操作が前提)
6. **CREATE2 フロントラン DoS** → `onlyOwner` で防止
7. **kill の不可逆性** → `Pausable` で可逆に変更
