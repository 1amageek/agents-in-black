# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

AgentsInBlack (AIB) is a workspace-first local runtime for developing Agents and MCP services across multiple independent Git repositories. It runs them locally via a single-port gateway, aligned with Google Cloud Run semantics.

Three deliverables exist in this repo:
- **`aib` CLI** — workspace init, sync, emulator control, deploy
- **`aib-dev` runtime** — Gateway (reverse proxy) + Supervisor (process orchestration)
- **AgentsInBlack macOS App** — SwiftUI UI that consumes `AIBCore`

## Concepts & Terminology

| Term | Definition |
|---|---|
| **Directory** (`AIBRepoModel`) | Git repository or local directory registered in the workspace. Contains source code and may host one or more Services. Not a primary sidebar item — serves as parent context for Services. |
| **Service** (`AIBServiceModel`) | The fundamental execution unit. A language-agnostic HTTP process managed by AIB. Identified by `namespacedID` (e.g. `agent-swift/main`). Primary sidebar item. |
| **Service Kind** | Classification of a Service: `agent` (A2A protocol required), `mcp` (MCP tool server), `unknown` (generic HTTP). Determines sidebar group and topology role. |
| **Workspace** | Root directory containing `.aib/workspace.yaml`. Aggregates multiple Directories and their Services. |
| **Actor Topology** | Directed connection graph between Services (agent→MCP, agent→agent). Persisted in `workspace.yaml`, visualized on the Flow Canvas. |

### Service-Centric UI Principle
- **Service is the fundamental UI unit** — all views (Canvas, Sidebar, Inspector) operate at the service level, not repo/directory level
- **Display name = package manifest name** — `AIBServiceModel.packageName` is derived from the package manifest (`package.json` "name", `Package.swift` `.executableTarget` name, etc.) and used as the primary display name everywhere in the UI
- **Display name priority**: `packageName` (from manifest) → `localID` (from workspace.yaml) → `namespacedID` (internal). Never show `namespacedID` as primary name.
- **`namespacedID` is secondary context** — shown as subtitle/caption text, never as the primary label
- **Unconfigured services**: use `AIBRepoModel.detectedPackageNames[runtime]` for display name (runtime → package name mapping populated during discovery)
- **Destructive actions (removal dialogs)**: always show `displayName` (packageName), not the internal `namespacedServiceID`
- **Sidebar grouping**: by `AIBServiceKind` (Agents / MCP / Other / Unconfigured)
- **Sidebar status**: per-Service, not per-directory
- **"Directory" vs "Repo"**: In UI and user-facing strings, prefer "Directory". `AIBRepoModel` remains for backward compatibility but represents a directory.

## Build & Test Commands

### SwiftPM (CLI + libraries)
```bash
swift build
swift test --timeout 30        # always set timeout to prevent hangs
```

### Run a single test suite
```bash
swift test --filter AIBConfigTests --timeout 30
swift test --filter AIBGatewayTests --timeout 30
swift test --filter AIBSupervisorTests --timeout 30
swift test --filter AIBWorkspaceTests --timeout 30
```

### macOS App
```bash
xcodebuild -project AgentsInBlack/AgentsInBlack.xcodeproj \
  -scheme AgentsInBlack -configuration Debug \
  -destination 'platform=macOS' build
```

### Demo workspace (end-to-end smoke test)
```bash
cd demo
../.build/debug/aib init --force
../.build/debug/aib emulator start --gateway-port 18080
# test: curl http://127.0.0.1:18080/agents/py/hello?x=1
# test: curl -X POST http://127.0.0.1:18080/mcp/node/echo -d 'ping'
```

## Architecture

### Invariants (never violate)
1. **`workspace.yaml`** (`.aib/workspace.yaml`) is the sole source of truth for all runtime config — no separate runtime manifest file exists
2. **`.aib/` exists only at the workspace root** — individual repositories are never invaded with AIB-specific files
3. Execution boundary = service (language-agnostic HTTP unit)
4. Local exposure via single port (Gateway)
5. Control Plane and Data Plane are separated
6. App never reimplements runtime logic — it depends on `AIBCore`
7. Unimplemented optional features must error explicitly, not silently no-op

### Module Responsibility Map

| Module | Role | Key Types |
|---|---|---|
| `AIBRuntimeCore` | Shared foundation types (IDs, errors, routes, traces, duration parsing) | `ServiceID`, `RoutePrefix`, `DurationParser` |
| `AIBConfig` | Config types + validation | `AIBConfig`, `AIBConfigValidator`, `LoadedConfig` |
| `AIBWorkspace` | Directory discovery, workspace sync, config resolution (workspace.yaml → AIBConfig) | `WorkspaceDiscovery`, `WorkspaceSyncer`, `AIBWorkspaceManager` |
| `AIBGateway` | NIOAsyncChannel-based reverse proxy (routing, timeout, header rewrite, concurrency) | `DevGateway`, `HTTPConnectionHandler`, `GatewayControl` |
| `AIBSupervisor` | Process lifecycle, health/readiness probes, restart, log mux | `DevSupervisor` (actor), `ConfigProvider`, `DefaultProcessController`, `LogMux` |
| `AIBCore` | App/CLI shared API — emulator control, deploy orchestration, workspace/service models, events | `AIBEmulatorController`, `AIBDeployController`, `AIBDeployService`, `AIBWorkspaceSnapshot`, `AIBServiceModel` |
| `AIBCLI` | CLI entry point dispatching to `AIBCore` | `AIBDevMain` (`@main`) |
| `AgentsInBlack App` | macOS SwiftUI UI, views, app state | `AgentsInBlackAppModel`, `ContentView` |

### Dependency Flow
```
AIBCLI ──→ AIBCore ──→ AIBWorkspace ──→ AIBConfig ──→ AIBRuntimeCore
                   ├──→ AIBGateway  ──→ AIBConfig ──→ AIBRuntimeCore
                   └──→ AIBSupervisor → AIBConfig ──→ AIBRuntimeCore
App ──→ AIBCore (only)
```

### Control Plane vs Data Plane
- **Control Plane** (`AIBConfig`, `AIBWorkspace`, `AIBSupervisor`): config loading, repo discovery, process orchestration, health checks
- **Data Plane** (`AIBGateway`): HTTP reverse proxy, routing by `mount_path`, path rewriting, timeout enforcement, concurrency limits

### CLI Commands (dispatch in `Sources/AIBCLI/main.swift`)
- `aib init` — bootstrap workspace, discover repos, write `.aib/workspace.yaml`
- `aib workspace list|scan|sync` — workspace management
- `aib emulator start|validate|status|stop` — local runtime control
- `aib deploy plan|apply` — deployment (CLI `apply` not yet implemented; App UI provides full deploy flow via `AIBDeployController`)

### Agent Communication — A2A Protocol Required

Agent services (`kind: agent`) must implement the [A2A (Agent-to-Agent) Protocol](https://a2a-protocol.org/latest/specification/). This is not optional.

#### Why A2A
- The Claude Agent SDK does not define a standard HTTP API — each developer wraps the SDK in a custom endpoint
- Without a standard protocol, AIB cannot auto-discover agent capabilities, chat endpoints, or streaming format
- Manual `ui.chat` configuration per agent is wrong — protocol-based discovery replaces it

#### Requirements for Agent Services
- **Agent Card**: must serve `/.well-known/agent.json` describing capabilities, endpoints, and supported methods
- **Transport**: JSON-RPC 2.0 over HTTPS with SSE for streaming
- **Discovery**: AIB reads the Agent Card at startup to determine how to communicate with the agent
- **Health**: `/health` endpoint (AIB readiness probe falls back to `/health` if `/health/ready` returns 404)

#### What This Means for AIB
- **No `ui.chat` config** — agent endpoint and message format are discovered from the Agent Card, not configured in workspace.yaml
- **InputBar availability** is determined by Agent Card presence, not by manual config
- **App UI** uses A2A protocol to send messages and receive streaming responses
- **Templates** (`ProjectScaffolder`) for agent-kind services must include A2A Agent Card boilerplate

### Actor Topology — Define → Persist → Generate → Run/Deploy

AIB's core purpose is managing **Actor Topology**: the connection graph between Agents and MCP servers. This topology is defined visually, persisted in workspace.yaml, and drives both local emulation and Cloud Run deployment.

```
Define (App UI)  →  Persist (.aib/workspace.yaml)  →  Resolve (in-memory AIBConfig + runtime/)  →  Run / Deploy
```

#### 1. Define — Actor Topology Canvas
- Users visually connect Agents to MCP servers (and Agents to Agents via A2A)
- Only Agents can be connection sources; targets are MCP or Agent services
- Connection types: MCP (agent uses MCP tools) and A2A (agent calls another agent)

#### 2. Persist — `.aib/workspace.yaml`
- Connections are stored as `connections.mcp_servers` and `connections.a2a_agents` on each Agent's service entry
- `service_ref` uses namespaced format: `{services_namespace}/{service_id}` (e.g., `mcp-node/web`)
- This is the single source of truth for topology

#### 3. Resolve — `WorkspaceSyncer.resolveConfig()`
- Flattens workspace.yaml repos into `AIBConfig` in memory (no intermediate file)
- Produces `.aib/generated/runtime/connections/{namespace}__{service_id}.json` per Agent
  - Contains resolved connection URLs for the local gateway (e.g., `http://localhost:8080/mcp/node/mcp`)
  - Injected into Agent processes as environment context

#### 4a. Local Emulator
- Gateway (single port) routes requests by `mount_path` to backend processes
- Supervisor starts processes, injects connection info, manages lifecycle
- Agent reaches MCP via gateway: `http://localhost:{gateway_port}/{mount_path}/{mcp_path}`

#### 4b. Deploy to Cloud Run
- Each service becomes an independent Cloud Run service
- `service_ref` resolves to Cloud Run service URL (e.g., `https://mcp-node-xxxxx.run.app/mcp`)
- Agent receives MCP server URL via environment variable `MCP_SERVER_URL`
- Agent authenticates to MCP using ID Token with IAM `roles/run.invoker`
- Transport: Streamable HTTP only (Cloud Run does not support stdin transport)
- CLI `deploy apply` is not yet implemented (stub returns error); App UI provides full deploy flow via `AIBDeployController` with phase-based UI

#### Cloud Run Alignment
- Each service = one Cloud Run service (language-agnostic HTTP unit)
- MCP transport must be `streamable_http` (Cloud Run requirement)
- Sidecar pattern: same-instance services use `localhost` (no auth needed)
- Service Mesh: short-name addressing (e.g., `http://mcp-server`)

### Cloud Run Deploy — What to Generate

Cloud Run has no special MCP config format. Required artifacts are standard container + Cloud Run primitives **plus** agent-specific Claude Code plugin bundles. AIB generates all of these from workspace.yaml topology.

#### Per-Service Artifacts

| Artifact | Placement | Purpose |
|---|---|---|
| Claude Code plugin bundle | Each agent's service directory | Agent-specific MCP binding + skills |
| `Dockerfile` | Each service directory | Container image build |
| `clouddeploy.yaml` | `.aib/generated/deploy/` | `gcloud run deploy` arguments (region, memory, concurrency, env vars) |

#### Claude Code Plugin Bundle — Per-Agent Format

Each Claude Code agent receives a generated plugin bundle. The bundle is static, and MCP endpoint URLs are rendered into it per environment.

| File | Purpose |
|---|---|
| `.claude-plugin/plugin.json` | Claude Code plugin manifest / metadata |
| `template.json` | Static service_ref-based MCP template |
| `binding.json` | Environment-specific resolved MCP URLs |
| `.mcp.json` / `.claude.json` | Claude Code-compatible rendered MCP config |
| `USE_WITH_CLAUDE.md` | `claude --plugin-dir <plugin-root>` の利用案内 |
| `__aib_deploy/.../skills` | Assigned skill payload projected into the plugin |

- Transport is always `streamable_http` for Cloud Run (stdio is not supported)
- URLs resolve differently per environment: local → `http://localhost:{port}/{path}`, Cloud Run → `https://{service}.run.app`
- `plugin = static package`, `binding = environment-specific render`
- Local Claude Code execution passes the plugin root via `--plugin-dir <plugin-root>`

#### Authentication & IAM
- Agent → MCP: ID Token with `roles/run.invoker` on the MCP service
- Private services: `--no-allow-unauthenticated` (default)
- IAM bindings generated per connection edge in topology

#### What AIB Does NOT Generate
- Application code or MCP client implementation (developer responsibility)
- API keys or secrets (managed externally via Secret Manager)
- VPC Connector config (infrastructure-level, out of scope for v1)

#### Service Identity — Package Manifest as Source of Truth

Service name is derived from the package manifest of each project, NOT from AIB internal naming. This name is used consistently across the entire system: UI display name (`AIBServiceModel.packageName`), Cloud Run service name, and Artifact Registry repository name.

| Runtime | Manifest | Service Unit | Name Source |
|---|---|---|---|
| Node | `package.json` | package (1:1) | `"name"` field |
| Swift | `Package.swift` | `.executableTarget` (1:N) | target name |
| Python | `pyproject.toml` | project (1:1) | `[project].name` |
| Deno | `deno.json` | module (1:1) | `"name"` field |

- Swift is the only runtime where 1 package can produce multiple services (one per executable target)
- If the manifest name cannot be determined, fall back to the directory name
- `RuntimeDetectionResult.serviceNames` stores extracted names

#### Artifact Registry — Provider Internal Detail

Artifact Registry repository naming is a GCP implementation detail. Users never configure it.

- **1 service = 1 Artifact Registry repository** (repository name = service name)
- Image tag format: `{region}-docker.pkg.dev/{gcpProject}/{serviceName}/service:latest`
- `artifactRegistryRepo` does not exist in user-facing target config
- Repository creation is automated per-service in the deploy pipeline (idempotent)

#### Deploy Architecture — Controller / Service / Executor / Provider

Deploy is orchestrated by four cooperating layers:

| Layer | Type | Responsibility |
|---|---|---|
| **Controller** | `AIBDeployController` | State machine (`AIBDeployPhase`), event streaming (`AsyncStream<AIBDeployEvent>`), gate coordination |
| **Service** | `AIBDeployService` | Plan generation, artifact writing, preflight checks, config loading |
| **Executor** | `DefaultDeployExecutor` (protocol `DeployExecuting`) | Command execution, progress tracking, real-time log streaming |
| **Provider** | `GCPCloudRunProvider` (protocol `DeploymentProvider`) | Cloud-specific commands, URL resolution, IAM bindings |
| **Process Runner** | `DefaultProcessRunner` (protocol `ProcessRunner`) | Async process execution via login shell (`zsh -l -c`), real-time line streaming |

#### Deploy Phase State Machine

```
idle → preflight → planning → reviewing → [secretsInput] → applying → completed | failed | cancelled
```

- **Gates**: `ApprovalGate` (user approves plan) and `SecretsGate` (user provides missing secret values)
- **Secrets gate**: queries remote (Cloud Run) for already-configured env vars, prompts only for **missing** secrets
- **Events**: `AIBDeployEvent` streamed to UI subscribers for real-time updates (phase changes + log entries)

#### Build Backend — apple/container CLI

AIB uses **apple/container CLI** (not Docker) for container image builds. Docker is unavailable in macOS app sandbox; apple/container integrates with the vmnet + UDS relay networking model.

- `ContainerCLIPolicy.ensureInstalled()` validates CLI availability before deploy and emulator start
- `BuildBackendAvailabilityChecker` verifies: CLI installed → builder running → default kernel configured
- Auto-setup: if builder reports "default kernel not configured", runs `container system kernel set --recommended` then `container builder start`
- `AppleContainerInstaller` (App only): fetches latest release from GitHub, downloads `.pkg`, runs admin installer, performs post-install setup

#### Deploy Pipeline

```
workspace.yaml  ──→  aib deploy plan   ──→  Show: services, connections, env vars, IAM
                ──→  aib deploy apply  ──→
                        1. Registry auth setup (once)
                           container registry login --username oauth2accesstoken --password-stdin
                        2. Per service:
                           a. Ensure Artifact Registry repo (idempotent create)
                           b. container build --platform linux/amd64
                           c. container image push --platform linux/amd64
                           d. gcloud run deploy (env vars with ^||^ delimiter)
                        3. Bind IAM invoker roles for connection edges
```

- Infrastructure setup (registry auth) runs once before all services
- Artifact Registry repo creation is per-service (repo = service)
- Process execution uses login shell (`zsh -l -c`) to inherit user PATH (Homebrew, gcloud SDK)
- `Foundation.Progress` tree: parent = total services, child = steps per service — observed by SwiftUI `ProgressView`

#### Preflight Check System

Provider-driven dynamic check system with dependency tracking.

- `PreflightCheckID` is a **struct** (not enum) — providers can define custom check IDs without modifying core
- Each `PreflightChecker` has an ID, title, async `run()` method, and returns `PreflightCheckResult` with status + remediation info
- Provider declares dependencies via `preflightDependencies()` — if a prerequisite fails, dependent checks are skipped
- Common checks: `.buildBackendAvailable` (apple/container CLI + builder + kernel)
- GCP checks: `.gcloudInstalled`, `.gcloudAuthenticated`, `.gcloudProjectConfigured`, `.cloudRunAPIEnabled`, `.cloudBuildAPIEnabled`
- Failed checks include: error message, remediation command (copyable in UI), documentation URL
- `cachedPreflightReport` stored in controller for re-display in failure view

#### Dockerfile Resolution (Priority-based)

1. `Dockerfile.{runtime}` (e.g., `Dockerfile.node`) — custom runtime-specific
2. `Dockerfile` — generic custom
3. Auto-generated using `DockerfileGeneratorRegistry.generator(for: runtime)`

#### Deploy Target Config

Stored at `.aib/targets/{providerID}.yaml`. Contains region, auth mode, resource defaults, and provider-specific config (e.g., GCP project ID). Auto-detected values (e.g., GCP project from `gcloud config`) merged during plan generation.

#### Key Constraint
- `service_ref` resolution differs by environment:
  - Local: `http://localhost:{gateway_port}/{mount_path}`
  - Cloud Run: `https://{service-name}-{region}.a.run.app`
- This resolution is the core job of `aib deploy plan` — it maps topology edges to concrete URLs

## Change Policy

### When modifying workspace.yaml schema or service config
1. Update `WorkspaceModels` + `WorkspaceYAMLCodec` in `AIBWorkspace`
2. Update `AIBConfig` types + `AIBConfigValidator` if needed
3. Reflect changes in `AIBCore` models
4. Update at least one test (Workspace or Config)
5. Update docs

### When modifying Gateway or Supervisor
- Never change one without verifying consistency with the other
- Failure logs must include `service_id`, `action`, and `reason`
- Gateway uses `NIOAsyncChannel` — never use `ChannelInboundHandler` or `ChannelHandlerContext` directly
- All channel I/O must go through `NIOAsyncChannelOutboundWriter` — never access `context.channel` from async contexts
- `DevGateway` lifecycle is managed by `Mutex<LifecyclePhase>` (idle → starting → running → stopped) — all transitions must be atomic

### When modifying App UI
- System/runtime errors and request-level errors must have separate display paths
- Inspector shows selection details only — never use it as the primary log/error surface
- **All user-visible errors and warnings must also be emitted to the emulator log stream** — UI-only errors (alerts, badges, toasts) that don't appear in `aib logs` make debugging impossible
- **Warning/error badges must include actionable context** — generic messages like "Runtime status: warning" are forbidden. Always include the specific reason (e.g., "No services configured", "Build failed: missing dependency")
- `lastErrorMessage` must be logged via the emulator logger before being displayed — never set it silently

### When modifying Deploy or Provider
- **Provider-specific check IDs, service names, CLI commands をハードコードしない** — すべて `DeploymentProvider` protocol 経由で取得する
- Check ID のフィルタリングは `provider.preflightCheckers()` や `provider.prerequisiteCheckIDs` から動的に導出する — `[.gcloudInstalled, ...]` のようなリテラル列挙は禁止
- **apple/container CLI が唯一のビルドバックエンド** — Docker CLI は使わない。`container build` / `container image push` / `container registry login` を使用する
- `ContainerCLIPolicy.ensureInstalled()` はデプロイ開始前とエミュレータ起動前の両方で呼び出す
- UI が Provider 情報を表示する場合は `provider.displayName` を使う — "GCP" 等の文字列リテラルを埋め込まない
- 新しい Provider を追加する際は `DeploymentProvider` を実装し `DeploymentProviderRegistry` に登録するだけで、App / CLI 側のコード変更は不要であるべき
- **サービス名はパッケージマニフェストから取得する** — AIB が独自に名前を生成しない。`RuntimeDetectionResult.serviceNames` が正規の名前源
- **Artifact Registry リポジトリ名 = サービス名** — ユーザーが設定する項目ではない。Provider 内部で自動処理する
- **インフラ準備（レジストリ認証、リポジトリ作成）はデプロイフロー内で自動実行する** — 手動設定を前提としない
- **デプロイフェーズの遷移は `AIBDeployController` のみが行う** — Service/Executor/Provider はフェーズを直接変更しない
- **シークレットはリモート照会後に未設定分のみプロンプトする** — 全シークレットを毎回入力させない

## Specifications
- Runtime spec: `docs/cloud-run-aligned-local-runtime-spec.md`
- CLI spec: `docs/aib-workspace-cli-spec.md`
- App spec: `docs/agents-in-black-app-v1-spec.md`
