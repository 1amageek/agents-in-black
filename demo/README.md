# AIB Demo Workspace

3言語（Python / Node.js / Swift）の Agent・MCP サービスが単一ゲートウェイで連携動作するデモです。

## アーキテクチャ

```
                ┌──────────────────────────────────────────────┐
                │            AIB Gateway (:8080)                │
                │     single-port reverse proxy + routing      │
                └──┬──────────┬───────────┬───────────┬────────┘
                   │          │           │           │
      /agents/py/* │ /mcp/node/* │ /mcp/web/* │ /agents/swift/*
                   │          │           │           │
          ┌────────▼──┐ ┌────▼─────┐ ┌───▼──────┐ ┌──▼────────────┐
          │ agent-py   │ │ mcp-node │ │ mcp-web  │ │ agent-swift   │
          │ (Python)   │ │ (Node.js)│ │ (Python) │ │ (Swift)       │
          │ kind:agent │ │ kind:mcp │ │ kind:mcp │ │ kind:agent    │
          └──┬─────┬───┘ └──────────┘ └──────────┘ │ SwiftAgent +  │
             │     │      MCP call ▲    MCP call ▲  │FoundationModels│
             │     └───────────────┘         │      └──┬─────┬──────┘
             └───────────────────────────────┘         │     │
                                          MCP call ────┘     │
                                          MCP call ──────────┘
```

**agent-py** と **agent-swift** は 2 つの MCP ツールサーバー（**mcp-node**, **mcp-web**）に接続し、ツール呼び出しを行います。
すべての通信は AIB Gateway を経由します。

## サービス一覧

| ID | Kind | Mount Path | Language | 概要 |
|----|------|-----------|----------|------|
| `agent-py/app` | agent | `/agents/py` | Python | チャット型エージェント。MCP ツールを呼び出す |
| `mcp-node/web` | mcp | `/mcp/node` | Node.js | MCP ツールサーバー (calculate, current_time, transform_text) |
| `mcp-web/web` | mcp | `/mcp/web` | Python | MCP ツールサーバー (fetch_url, extract_links, search_page) |
| `agent-swift/app` | agent | `/agents/swift` | Swift | SwiftAgent + Apple Intelligence エージェント。MCP ツールを呼び出す |

## 前提

- `swift build` 済み（CLI バイナリ）
- `python3` が使える
- `node` が使える
- `swift` 6.2+ が使える（agent-swift ビルド用）

## セットアップと起動

```bash
# 1. CLI をビルド
cd /Users/1amageek/Desktop/agents-in-black
swift build

# 2. ワークスペースを初期化（3 repo を検出・合成）
cd demo
../.build/debug/aib init --force

# 3. エミュレータ起動（デフォルトポート 8080）
../.build/debug/aib emulator start
```

> agent-swift は初回起動時に `swift build` が走るため、起動まで時間がかかります。

## 動作確認

### ヘルスチェック

```bash
curl -sS http://127.0.0.1:8080/agents/py/health/ready
curl -sS http://127.0.0.1:8080/mcp/node/health/ready
curl -sS http://127.0.0.1:8080/mcp/web/health/ready
curl -sS http://127.0.0.1:8080/agents/swift/health/ready
```

### MCP Node ツール直接呼び出し

```bash
# ツール一覧
curl -sS http://127.0.0.1:8080/mcp/node/mcp

# 計算
curl -sS -X POST http://127.0.0.1:8080/mcp/node/mcp \
  -H 'Content-Type: application/json' \
  -d '{"tool":"calculate","params":{"expression":"2+3*4"}}'
# => {"result":14}

# テキスト変換
curl -sS -X POST http://127.0.0.1:8080/mcp/node/mcp \
  -H 'Content-Type: application/json' \
  -d '{"tool":"transform_text","params":{"text":"hello world","operation":"uppercase"}}'
# => {"result":"HELLO WORLD"}
```

### MCP Web ツール直接呼び出し

```bash
# ツール一覧
curl -sS http://127.0.0.1:8080/mcp/web/mcp

# URL 取得
curl -sS -X POST http://127.0.0.1:8080/mcp/web/mcp \
  -H 'Content-Type: application/json' \
  -d '{"tool":"fetch_url","params":{"url":"https://example.com","max_length":"500"}}'

# リンク抽出
curl -sS -X POST http://127.0.0.1:8080/mcp/web/mcp \
  -H 'Content-Type: application/json' \
  -d '{"tool":"extract_links","params":{"url":"https://example.com"}}'

# ページ内検索
curl -sS -X POST http://127.0.0.1:8080/mcp/web/mcp \
  -H 'Content-Type: application/json' \
  -d '{"tool":"search_page","params":{"url":"https://example.com","query":"example"}}'
```

### Agent Python → MCP ツール呼び出し

```bash
# チャットエンドポイント（キーワードに応じて MCP ツールを呼ぶ）
curl -sS -X POST http://127.0.0.1:8080/agents/py/ \
  -H 'Content-Type: application/json' \
  -d '{"message":"calculate 10+20"}'

# ツール直接呼び出し
curl -sS -X POST http://127.0.0.1:8080/agents/py/call \
  -H 'Content-Type: application/json' \
  -d '{"tool":"calculate","params":{"expression":"99/3"}}'

# 利用可能ツール一覧（MCP サーバーから取得）
curl -sS http://127.0.0.1:8080/agents/py/tools
```

### Agent Swift → MCP ツール呼び出し（LLM 経由）

```bash
# Apple Intelligence が MCP ツールを判断して呼び出す
curl -sS -X POST http://127.0.0.1:8080/agents/swift/ \
  -H 'Content-Type: application/json' \
  -d '{"message":"calculate 7*8"}'
```

### 自動テスト

```bash
bash test.sh
```

## 停止

起動中のターミナルで `Ctrl-C` を使用してください。

## ディレクトリ構成

```
demo/
  agent-py/          Python Agent repo (server.py)
  agent-swift/       Swift Agent repo (Package.swift)
  mcp-node/          Node.js MCP repo (server.js)
  mcp-web/           Python MCP repo (server.py) — Web ツール
  .aib/              workspace 設定・生成物（workspace.yaml, services.yaml, state, logs）
  test.sh            統合テストスクリプト
```

> `.aib/` はワークスペースルート（`demo/`）にのみ存在します。各リポジトリディレクトリ内に `.aib/` は作成されません。

## 既知の制約

- `Ctrl-C` 終了時に Gateway 側でクラッシュすることがある
- `aib emulator stop` は foreground 起動の停止に失敗する場合がある
- `aib deploy apply` は未実装
- agent-swift は初回ビルドに時間がかかる（SwiftPM パッケージ解決 + コンパイル）
