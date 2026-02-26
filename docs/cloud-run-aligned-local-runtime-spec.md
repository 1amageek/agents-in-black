# AgentsInBlack Cloud Run-Aligned Local Runtime Specification (v1)

Status: Draft (Spec Freeze for v1 implementation)

## 1. 目的

この仕様は、ローカル開発環境において Cloud Run / Cloud Functions Gen2 の実行モデルに整合するマルチプロセス実行基盤を定義する。

### 1.1 設計目標

- `G1` Cloud Run / Cloud Functions Gen2 の実行モデルをローカルで整合的に再現する
- `G2` サービス単位の独立性を保持する
- `G3` 単一ポートでアクセスできる開発体験を提供する
- `G4` Swift / TypeScript 混在実行を可能にする
- `G5` 本番との差分を最小化する
- `G6` ロジックホットリロードは各言語ランタイムに委譲する
- `G7` 構造変更はサービス単位で再起動する

### 1.2 用語

- `DevGateway`: ローカル単一ポートを提供する reverse proxy（Local Load Balancer）
- `DevSupervisor`: 子プロセス管理・再起動制御・変更検知を行う Orchestrator
- `Service`: 言語非依存の HTTP Unit（Swift/TS/将来Python等）
- `services.yaml`: ローカル runtime の唯一の設定ソース（source of truth）

## 2. スコープ

### 2.1 v1で再現するもの

- サービス単位の実行境界
- サービス単位の障害分離
- サービス単位の再起動
- HTTP 経由通信
- ヘッダー注入（Forwarded / Request ID / 擬似 Trace）
- タイムアウト制御
- 同時実行数制限（単一インスタンス模擬）

### 2.2 v1で再現しないもの（非目標）

- 実際のオートスケール
- GFE の完全な挙動再現
- 実 IAM の完全検証
- 本番 revision 配備モデルの完全再現

備考:
- 本仕様は `Cloud Run-Accurate` ではなく `Cloud Run-Aligned` を名乗る。

## 3. 全体アーキテクチャ

```text
                    ┌────────────────────────┐
                    │ DevGateway             │
                    │ Port: 8080             │
                    │ (Local Load Balancer)  │
                    └──────────┬─────────────┘
                               │ Reverse Proxy
      ┌────────────────────────┼────────────────────────┐
      │                        │                        │
┌──────────────┐        ┌──────────────┐        ┌──────────────┐
│ Swift AgentA │        │ Swift MCPWeb │        │ TS FunctionX │
│ Port: 9001   │        │ Port: 9002   │        │ Port: 9003   │
└──────────────┘        └──────────────┘        └──────────────┘
```

### 3.1 設計原則

- `DevGateway` は言語を知らない
- すべての backend を HTTP サービスとして扱う
- 実行境界・障害境界・再起動境界は `Service` 単位に一致させる

## 4. サービス抽象（Language-Agnostic HTTP Unit）

すべてのサービスは以下を満たすこと。

- `S1` HTTP サーバである
- `S2` 指定ポートで待受可能である
- `S3` `SIGTERM` で終了可能である
- `S4` 健康確認エンドポイントを持つ（liveness/readiness）

### 4.1 実行環境契約

- `PORT` 環境変数を優先して bind することを推奨
- ローカル bind は既定で `127.0.0.1`
- `SIGTERM` 受信時は graceful shutdown を試みる

## 5. 設定ソース（services.yaml）

### 5.1 責務

`services.yaml` を runtime 設定の唯一の source of truth とする。

- `DevGateway` のルーティングテーブル生成元
- `DevSupervisor` の起動/監視/再起動対象定義元

### 5.2 Plugin の位置づけ

Build Tool Plugin は以下に限定する。

- Swift サービスの補助生成
- `services.yaml` 検証補助

禁止:
- `services.yaml` と競合する権威設定の生成

### 5.3 設定読み込み実装標準（Swift）

`DevGateway` および `DevSupervisor`（Swift 実装）は、設定読み込みに `apple/swift-configuration` を使用する。

目的:

- 設定 provider の統一
- YAML / 環境変数 / CLI の階層的合成
- 将来の reloading / access logging 拡張の一貫性確保

参考実装ライブラリ:

- `Configuration` package（apple/swift-configuration）

### 5.4 provider 構成ポリシー（v1）

`swift-configuration` の provider 階層は、優先度の高い順に以下を推奨する。

1. `CommandLineArgumentsProvider`（任意）
2. `EnvironmentVariablesProvider`
3. `FileProvider<YAMLSnapshot>` または `ReloadingFileProvider<YAMLSnapshot>`

補足:

- `YAMLSupport` trait を有効化する
- `ReloadingSupport` trait は DevSupervisor での設定ファイル再読込に使用可能
- `CommandLineArgumentsSupport` trait は CLI override が必要な場合に有効化

### 5.5 Source of Truth と override の整合ルール

`swift-configuration` は複数 provider の合成を提供するが、本仕様における source of truth は引き続き `services.yaml` とする。

v1 では次のルールを適用する。

- `services.yaml` は再現性のある構造定義（サービス一覧・ルーティング・起動コマンド）の正本
- 環境変数 / CLI override は運用補助用途に限定する（例: gateway port, log level, config file path）
- サービス構造を変える override（例: `services[*].mount_path`, `run`, `id` の差し替え）は v1 では非推奨（実装する場合は明示フラグ必須）

目的:

- ローカル再現性を維持しつつ、開発運用で必要な局所 override を許可する

## 6. DevGateway 仕様

## 6.1 概要

DevGateway はローカル単一ポートを提供する path-based reverse proxy とする。

- 単一ポート公開（例: `:8080`）
- services.yaml 由来のルーティング
- HTTP 契約の透過転送 + 最小限の補正

## 6.2 パスベースルーティング

ルーティングテーブルは `services.yaml` から生成する。

例:

- `/agents/a/* -> http://127.0.0.1:9001`
- `/mcp/web/* -> http://127.0.0.1:9002`
- `/functions/x/* -> http://127.0.0.1:9003`

### 6.2.1 パス転送規約

各サービスに `mount_path` と `path_rewrite` を定義する。

- `path_rewrite: strip_prefix`（既定）
- `path_rewrite: preserve`

`strip_prefix` の場合:
- クライアント `/agents/a/foo` -> backend `/foo`
- `X-Forwarded-Prefix: /agents/a` を付与

`preserve` の場合:
- クライアント `/agents/a/foo` -> backend `/agents/a/foo`

## 6.3 HTTP/接続仕様

v1 必須:

- HTTP/1.1
- Keep-Alive
- Chunked Transfer Encoding
- Streaming Response

v1 optional:

- WebSocket Proxy（feature flag）

### 6.3.1 ストリーミング方針

- request/response ともに既定で非バッファリング
- chunk は逐次転送
- backpressure を尊重する

### 6.3.2 WebSocket（v1 optional）

- `websocket.enabled=true` 時のみ有効
- Upgrade を透過転送
- フレーム内容は解釈しない

## 6.4 ヘッダー仕様

DevGateway は以下の代表的ヘッダーを注入または補完する。

- `X-Forwarded-For`（append）
- `X-Forwarded-Proto`（ローカル既定: `http`）
- `X-Forwarded-Host`
- `X-Request-Id`（常に生成）
- `X-Cloud-Trace-Context`（擬似生成）

推奨（任意）:
- `traceparent`

### 6.4.1 Host ヘッダー

- 既定では client の `Host` を維持する
- backend が origin host を必要とする場合はサービス単位設定で上書きを許可してよい（v1 optional）

## 6.5 レスポンスヘッダー補正

`path_rewrite=strip_prefix` のとき、必要に応じて次を補正する。

- `Location` ヘッダーに `mount_path` prefix を再付与
- `Set-Cookie` の `Path` を `mount_path` に書き換え（既定）

目的:
- サービス間の cookie 汚染防止
- redirect のクライアント整合性確保

サービス単位で以下を許可:

- `cookie_path_rewrite: false`

## 6.6 タイムアウト仕様

タイムアウトは DevGateway で一元適用する。

定義:

- `header_timeout`
- `backend_connect_timeout`
- `backend_response_header_timeout`
- `idle_timeout`
- `request_timeout`

### 6.6.1 意味

- `header_timeout`: client request header 完了まで
- `backend_connect_timeout`: backend 接続確立まで
- `backend_response_header_timeout`: backend 転送後に response header を受けるまで
- `idle_timeout`: 双方向でデータ流量がない最大時間
- `request_timeout`: request 開始から response 完了までの総時間上限

### 6.6.2 超過時の挙動

- response 未開始: `504 Gateway Timeout`
- response 開始後: 接続を切断
- すべての timeout 事象はログに timeout 種別付きで記録

## 6.7 認証エミュレーション（optional）

v1 は IAM の完全再現ではなく、開発用アクセス制御を提供する。

サービス単位 `auth.mode`:

- `off`
- `bearer-any`
- `static-token`
- `mock-jwt`

任意で backend に認証結果を注入可能:

- `X-AIB-Auth-Subject`
- `X-AIB-Auth-Claims`（必要時）

## 6.8 Concurrency 制御

これは Cloud Run のスケール再現ではなく、単一インスタンスに対する受付制限の模擬である。

### 6.8.1 カウント単位

- `in-flight HTTP request 数`
- WebSocket は接続期間中 `1` としてカウント

### 6.8.2 動作

- 既定値: `max_inflight = 80`
- 上限超過時既定: `503 Service Unavailable`
- `overflow_mode: queue` は v1 optional
- queue 使用時は `queue_timeout` 超過で `503`

## 7. DevSupervisor 仕様

## 7.1 概要

DevSupervisor はローカル Orchestrator であり、プロセス管理・変更検知・再起動制御を担当する。

責務:

- 子プロセス起動
- ログ収集
- liveness/readiness 監視
- 構造変更差分適用
- 再起動/backoff 管理

## 7.2 サービス定義（services.yaml）

各サービス定義は最低限以下を持つ。

- `id`
- `mount_path`
- `port`（`0` 許可）
- `run`（必須）
- `cwd`（任意）
- `watch_mode`
- `health`
- `restart`

ビルド/依存解決は任意:

- `build`
- `install`

## 7.3 プロセス管理

### 7.3.1 起動

- 各サービスは新しい process group/session で起動する
- `PORT` 環境変数を注入する（実割当ポート）

### 7.3.2 停止

停止は process group 単位で行う。

手順:

1. `SIGTERM` 送信
2. `shutdown_grace_period` 待機
3. 未終了なら `SIGKILL`

目的:
- `npm run dev` 等の孫プロセス化を吸収する

## 7.4 Health / Readiness / Drain

### 7.4.1 エンドポイント規約

既定値:

- `liveness_path: /health/live`
- `readiness_path: /health/ready`

### 7.4.2 判定の使い分け

- `readiness`: 起動完了判定、ルーティング受付可否判定
- `liveness`: 運用中の生存判定

### 7.4.3 再起動時の drain

対象サービスは再起動時に `draining` に入る。

- 新規 request は受けない（既定: `503`）
- in-flight request は `drain_timeout` まで待つ
- 超過時は停止シーケンスに移行

## 7.5 サービス状態機械（固定）

状態:

- `stopped`
- `starting`
- `ready`
- `unhealthy`
- `draining`
- `stopping`
- `backoff`

主要遷移:

- `stopped -> starting`
- `starting -> ready`（readiness 成功）
- `starting -> backoff`（起動失敗 / timeout）
- `ready -> unhealthy`（連続ヘルス失敗）
- `ready -> draining`（再起動/設定変更）
- `draining -> stopping`（drain 完了 or timeout）
- `stopping -> starting`（再起動）
- `stopping -> stopped`（削除）
- `backoff -> starting`（backoff 経過）

### 7.5.1 Backoff

- exponential backoff + jitter
- 上限時間あり
- 明示的設定変更イベント時は backoff を短絡して再試行可能

## 7.6 構造変更対応（services.yaml 差分適用）

対象:

- サービス追加
- サービス削除
- `port` 変更
- `mount_path` 変更
- `run/build/install/cwd/watch_mode` 等の起動条件変更

### 7.6.1 差分適用ルール

1. `services.yaml` 変更検知
2. parse / validate
3. 差分解析（add/update/remove）
4. 新規/更新対象を起動
5. readiness 成功後に Gateway ルーティング切替
6. 旧対象を drain -> stop

失敗時:
- 切替を行わず旧設定を維持（atomic reload）

### 7.6.2 `swift-configuration` による reload イベントの扱い

`ReloadingFileProvider<YAMLSnapshot>` を使用する場合でも、Supervisor は provider からの変更通知をそのまま逐次適用してはならない。

必須ルール:

1. 更新スナップショットを parse / validate
2. 差分を計算
3. atomic reload 手順（`7.6.1`）で適用
4. 失敗時は旧ルーティング / 旧プロセスを維持

理由:

- provider の reload 通知は入力変化の検知であり、runtime 適用成功を保証しないため

## 7.7 変更検知と再起動ポリシー

各サービスに `watch_mode` を定義する。

- `external`: Supervisor が変更検知して再起動（Swift 既定）
- `internal`: サービス自身が watch/hot reload（TS 既定）

### 7.7.1 watch_paths

- `watch_mode=external` のサービスのみ Supervisor が `watch_paths` を監視し再起動する
- `watch_mode=internal` では Supervisor は死活のみ監視し、ソース変更には干渉しない

### 7.7.2 restart_affects

共有ライブラリ変更など複数サービスへ影響がある場合、`restart_affects` に列挙されたサービス群を再起動対象とする。

### 7.7.3 安全側ルール

- 判定不能な変更: 対象サービス再起動
- 影響範囲不明: Supervisor の設定 reload（全停止はしない）

## 7.8 サービス単位ビルド / install

変更検知時の実行順序（`watch_mode=external`）:

1. `install`（lockfile 変更時のみ）
2. `build`（定義されていれば）
3. 成功時のみ restart

失敗時:
- 旧プロセスを維持
- 失敗ログを表示

## 8. ロジックホットリロード（各言語委譲）

本仕様はロジックホットリロードの実装方式を runtime 共通仕様としては規定しない。各言語ランタイムに委譲する。

### 8.1 Swift（例）

- `@_dynamicReplacement`
- Debug (`-Onone`)
- `static func` ベース

### 8.2 TypeScript（例）

- `nodemon`
- `ts-node-dev`
- その他ランタイム内 watch 機構

DevSupervisor は内部ホットリロードには干渉せず、プロセス死活のみを管理する。

## 9. ログ / トレース統合

## 9.1 Supervisor ログ統合

- 各サービス `stdout/stderr` を行単位で収集
- 各行に `service_id` を付与して表示

例:

```text
[agent-a] INFO ...
[mcp-web] ERROR ...
[ts-function-x] DEBUG ...
```

## 9.2 Gateway アクセスログ

必須項目:

- `timestamp`
- `service_id`
- `method`
- `path`
- `status`
- `latency`
- `request_id`
- `trace_id`（生成時）

## 10. 本番との差分最小化戦略

本番:

- Cloud Run Load Balancer / GFE
- Container Instance

ローカル:

- DevGateway
- DevSupervisor
- Local Process

差分として明示するもの:

- 実 GFE は存在しない
- 実スケールは行わない（模擬のみ）
- IAM 検証は開発向け簡略化

## 11. 拡張可能性（v2+）

- HTTP/2 サポート
- gRPC Proxy
- Traffic Splitting 模擬
- Revision 切替エミュレーション
- Canary テスト

## 12. services.yaml v1 スキーマ（推奨例）

```yaml
version: 1

gateway:
  port: 8080
  timeouts:
    header: 10s
    backend_connect: 5s
    backend_response_header: 30s
    idle: 60s
    request: 300s
  websocket:
    enabled: false

services:
  - id: agent-a
    mount_path: /agents/a
    port: 0
    cwd: ./agent-a
    run: ["swift", "run", "agent-a"]
    build: ["swift", "build"]
    watch_mode: external
    watch_paths: ["Sources/**", "Package.swift", "Package.resolved"]
    restart_affects: ["agent-a"]
    path_rewrite: strip_prefix
    env:
      AIB_SERVICE_ID: agent-a
    health:
      liveness_path: /health/live
      readiness_path: /health/ready
      startup_ready_timeout: 30s
      check_interval: 2s
      failure_threshold: 3
    restart:
      drain_timeout: 10s
      shutdown_grace_period: 10s
      backoff_initial: 1s
      backoff_max: 30s
    concurrency:
      max_inflight: 80
      overflow_mode: reject
    auth:
      mode: off

  - id: ts-function-x
    mount_path: /functions/x
    port: 0
    cwd: ./ts-function-x
    run: ["npm", "run", "dev"]
    install: ["npm", "install"]
    watch_mode: internal
    watch_paths: ["package.json", "package-lock.json"]
    path_rewrite: strip_prefix
    health:
      liveness_path: /health/live
      readiness_path: /health/ready
      startup_ready_timeout: 60s
    restart:
      drain_timeout: 5s
      shutdown_grace_period: 5s
    concurrency:
      max_inflight: 80
      overflow_mode: reject
    auth:
      mode: bearer-any
```

## 13. 実装前に固定済みの設計判断（要約）

- `services.yaml` が唯一の source of truth
- `DevGateway` は `path_rewrite=strip_prefix` を既定とする
- `liveness` / `readiness` を分離する
- 再起動は `drain -> stop -> start -> ready -> route切替` を基本とする（atomic reload）
- 子プロセスは process group 単位で管理する
- `watch_mode` で Supervisor と各言語 watch の責務を分離する
- `port: 0` を許可し `PORT` 環境変数を注入する
- concurrency 制御は単一インスタンス受付制限の模擬と位置づける
- Swift 実装の設定読み込みは `apple/swift-configuration` を標準とする

## 14. 実装ガイド（swift-configuration 採用方針）

本仕様の Swift 実装（DevGateway / DevSupervisor）では、`apple/swift-configuration` の以下 trait を推奨する。

- `YAMLSupport`（必須）
- `ReloadingSupport`（DevSupervisor 推奨）
- `CommandLineArgumentsSupport`（CLI override を使う場合）
- `LoggingSupport`（設定アクセス監査が必要な場合）

### 14.1 推奨用途

- `services.yaml` の読み込み（YAML）
- `--config` などの CLI 指定
- `AIB_GATEWAY_PORT` 等の環境変数 override
- 設定変更検知の入口（Reloading provider）

### 14.2 非推奨用途（v1）

- provider 合成でサービス構造を暗黙に動的変更すること
- `services.yaml` の source-of-truth 性を崩す override 運用

## 15. 残課題（実装仕様化フェーズで詰める）

次フェーズで詳細を固定する。

- `Location` / `Set-Cookie` / WebSocket のエッジケース一覧
- Gateway の timeout 実装時の切断タイミング詳細
- Supervisor の差分適用アルゴリズム（追加/更新/削除の順序、失敗時ロールバック条件）
- `services.yaml` JSON Schema もしくは厳密バリデータ仕様
