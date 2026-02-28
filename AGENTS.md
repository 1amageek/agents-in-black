# AgentsInBlack 実装運用契約

## 1. 目的とスコープ

このリポジトリは、複数 Git リポジトリで管理される Agent/MCP を、ローカルで Cloud Run-Aligned に統合実行するための基盤です。  
対象は以下です。

- `aib` CLI（workspace 初期化・同期・実行）
- `aib-dev` 相当ランタイム（Gateway + Supervisor）
- `AgentsInBlack` macOS App（AIBCore を使う UI）

## 2. アーキテクチャ不変条件（壊してはいけない契約）

1. `services.yaml`（workspace `.aib/services.yaml`）がローカル実行の source of truth
2. **`.aib/` はワークスペースルートにのみ存在する** — 個別リポジトリに AIB 固有のファイルやディレクトリを作成しない
3. 実行境界は service 単位（言語非依存 HTTP Unit）
4. ローカル公開は単一ポート（Gateway 経由）
5. Control Plane（設定/起動制御）と Data Plane（HTTP転送）は責務分離
6. App はランタイム本体を再実装しない（`AIBCore` を利用）
7. optional 未実装機能は暗黙 no-op にせず、明示エラーで止める

## 3. 責務境界（どこを編集すべきか）

### 3.1 Control Plane
- `Sources/AIBCLI`
  - CLI surface（`aib init/workspace/emulator/deploy`）
- `Sources/AIBWorkspace`
  - repo discovery・workspace 同期・サービス設定生成
- `Sources/AIBConfig`
  - config decode/validate
- `Sources/AIBSupervisor`
  - process orchestration、health/readiness、restart、log mux

### 3.2 Data Plane
- `Sources/AIBGateway`
  - reverse proxy、routing、timeout、header rewrite、concurrency

### 3.3 Shared
- `Sources/AIBRuntimeCore`
  - 共通型（ID、Error、Route、Trace）
- `Sources/AIBCore`
  - App/CLI 共通 API（エミュレータ制御、workspace/service モデル、イベント）

### 3.4 App Layer
- `AgentsInBlack/AgentsInBlack`
  - UI・UX、表示状態、外部エディタ起動
  - 仕様: UIは `AIBCore` 依存、ランタイム仕様は Core 側に寄せる

## 4. 変更ポリシー

1. `services.yaml` スキーマ変更時:
- `AIBConfig` の decode + validation を更新
- `AIBCore` モデルへの反映
- 最低 1 つのテスト更新（Config または E2E相当）
- docs 更新（spec/README）

2. Gateway/Supervisor の挙動変更時:
- 片側だけ変更しない（制御とデータの整合を確認）
- 失敗時のログ文脈（service_id, action, reason）を必須化

3. App UI 変更時:
- system/runtime error と request-level error の表示責務を混ぜない
- Inspector は selection 詳細のみ（ログ/エラーの主表示場所にしない）

4. 互換性:
- 既存 CLI コマンド互換を壊す変更は明示的に扱う
- デフォルト挙動変更はドキュメントと demo を同時更新

## 5. 実行・検証手順（標準）

### 5.1 SwiftPM
- Build: `swift build`
- Test: `swift test`

### 5.2 macOS App
- Build:  
  `xcodebuild -project /Users/1amageek/Desktop/agents-in-black/AgentsInBlack/AgentsInBlack.xcodeproj -scheme AgentsInBlack -configuration Debug -destination 'platform=macOS' build`

### 5.3 Demo Workspace
- `cd /Users/1amageek/Desktop/agents-in-black/demo`
- `../.build/debug/aib init --force`
- `../.build/debug/aib emulator start --gateway-port 18080`

## 6. Done 条件（最低）

1. 変更対象モジュールがビルド可能  
2. 影響範囲のテストが通る（少なくとも関連スイート）  
3. 失敗時ログが追跡可能（原因が特定できる）  
4. 仕様変更なら docs/README の差分がある

## 7. 禁止事項

- `try?` によるエラー握りつぶし
- optional 未実装機能の暗黙無効化
- App 層でのランタイム重複実装
- source of truth を増やす変更（`services.yaml` と競合する設定導入）
- 個別リポジトリ内に `.aib/` ディレクトリやファイルを作成すること

## 8. 参照起点

- CLI entry: `Sources/AIBCLI/main.swift`
- App entry: `AgentsInBlack/AgentsInBlack/AgentsInBlackApp.swift`
- 仕様基準: `docs/cloud-run-aligned-local-runtime-spec.md`
