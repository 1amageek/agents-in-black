# AIB Emulator Demo Workspace

`AgentsInBlack` の workspace-first モデルを確認するための最小デモです。

この `demo/` は、独立した Git 管理を想定した 2 つの擬似 repo を並べています。

- `agent-py` (Python / HTTP server)
- `mcp-node` (Node.js / HTTP server)

両方の repo は repo 側 manifest（`.aib/services.yaml`）を持ち、AIB はそれを読み取って
workspace の `.aib/services.yaml` を合成します。

## 目的

- `aib init` で multi-repo workspace を発見できること
- `aib emulator start` で単一ポートに束ねて実行できること
- 言語の異なる service を同時実行できること

## 前提

- `/Users/1amageek/Desktop/agents-in-black` で `swift build` 済み
- `python3` が使える
- `node` が使える

## 起動手順

```bash
cd /Users/1amageek/Desktop/agents-in-black/demo
../.build/debug/aib init --force
../.build/debug/aib workspace list
../.build/debug/aib emulator start --gateway-port 18080
```

`aib emulator start` は foreground 実行です。

## エンドポイント

- Python Agent: `http://127.0.0.1:18080/agents/py/*`
- Node MCP: `http://127.0.0.1:18080/mcp/node/*`

### 動作確認例

```bash
# zsh では ? を含むURLはクォートする
curl -sS 'http://127.0.0.1:18080/agents/py/hello?x=1'

curl -sS -X POST 'http://127.0.0.1:18080/mcp/node/echo' -d 'ping'

curl -sS 'http://127.0.0.1:18080/agents/py/health/ready'
curl -sS 'http://127.0.0.1:18080/mcp/node/health/ready'
```

期待されるレスポンス例:

```json
{"service": "agent-py/app", "path": "/hello?x=1", "method": "GET"}
```

```json
{"service":"mcp-node/web","method":"POST","path":"/echo","body":"ping"}
```

## 停止

現状は `aib emulator stop` に既知の不具合があるため、起動中の端末で `Ctrl-C` を使ってください。

## 既知の制約（現時点）

- `Ctrl-C` 終了時に Gateway 側でクラッシュすることがある（終了パスの不具合）
- `aib emulator stop` は foreground 起動の停止に失敗する場合がある
- `aib deploy apply` は未実装

## ディレクトリ構成

```text
demo/
  agent-py/        # Python demo repo (.git / .aib/services.yaml)
  mcp-node/        # Node demo repo (.git / .aib/services.yaml)
  .aib/            # workspace生成物 (workspace.yaml, services.yaml, state, logs)
```
