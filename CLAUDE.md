# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

AgentsInBlack (AIB) is a workspace-first local runtime for developing Agents and MCP services across multiple independent Git repositories. It runs them locally via a single-port gateway, aligned with Google Cloud Run semantics.

Three deliverables exist in this repo:
- **`aib` CLI** — workspace init, sync, emulator control, deploy
- **`aib-dev` runtime** — Gateway (reverse proxy) + Supervisor (process orchestration)
- **AgentsInBlack macOS App** — SwiftUI UI that consumes `AIBCore`

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
1. **`services.yaml`** (workspace `.aib/services.yaml`) is the sole source of truth for local runtime config
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
| `AIBConfig` | Decode + validate `services.yaml` | `AIBConfig`, `AIBConfigLoader`, `AIBConfigValidator` |
| `AIBWorkspace` | Repo discovery, workspace sync, service config generation | `WorkspaceDiscovery`, `WorkspaceSyncer`, `AIBWorkspaceManager` |
| `AIBGateway` | NIOAsyncChannel-based reverse proxy (routing, timeout, header rewrite, concurrency) | `DevGateway`, `HTTPConnectionHandler`, `GatewayControl` |
| `AIBSupervisor` | Process lifecycle, health/readiness probes, restart, log mux | `DevSupervisor` (actor), `DefaultProcessController`, `LogMux` |
| `AIBCore` | App/CLI shared API — emulator control, workspace/service models, events | `AIBEmulatorController`, `AIBWorkspaceSnapshot`, `AIBServiceModel` |
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
- `aib init` — bootstrap workspace, discover repos, generate `.aib/services.yaml`
- `aib workspace list|scan|sync` — workspace management
- `aib emulator start|validate|status|stop` — local runtime control
- `aib deploy plan|apply` — deployment (apply not yet implemented)

### Actor Topology — Define → Persist → Generate → Run/Deploy

AIB's core purpose is managing **Actor Topology**: the connection graph between Agents and MCP servers. This topology is defined visually, persisted in workspace.yaml, and drives both local emulation and Cloud Run deployment.

```
Define (App UI)  →  Persist (.aib/workspace.yaml)  →  Generate (services.yaml + runtime/)  →  Run / Deploy
```

#### 1. Define — Actor Topology Canvas
- Users visually connect Agents to MCP servers (and Agents to Agents via A2A)
- Only Agents can be connection sources; targets are MCP or Agent services
- Connection types: MCP (agent uses MCP tools) and A2A (agent calls another agent)

#### 2. Persist — `.aib/workspace.yaml`
- Connections are stored as `connections.mcp_servers` and `connections.a2a_agents` on each Agent's service entry
- `service_ref` uses namespaced format: `{services_namespace}/{service_id}` (e.g., `mcp-node/web`)
- This is the single source of truth for topology

#### 3. Generate — `aib workspace sync`
- Produces `.aib/services.yaml` (gateway routing config) from workspace.yaml
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
- `deploy apply` is not yet implemented — current stub in CLI

#### Cloud Run Alignment
- Each service = one Cloud Run service (language-agnostic HTTP unit)
- MCP transport must be `streamable_http` (Cloud Run requirement)
- Sidecar pattern: same-instance services use `localhost` (no auth needed)
- Service Mesh: short-name addressing (e.g., `http://mcp-server`)

### Cloud Run Deploy — What to Generate

Cloud Run has no special MCP config format. Required artifacts are standard container + Cloud Run primitives **plus** agent-specific MCP connection config files. AIB generates all of these from workspace.yaml topology.

#### Per-Service Artifacts

| Artifact | Placement | Purpose |
|---|---|---|
| MCP connection config | Each agent's service directory | Agent-specific format (see below) |
| `Dockerfile` | Each service directory | Container image build |
| `clouddeploy.yaml` | `.aib/generated/deploy/` | `gcloud run deploy` arguments (region, memory, concurrency, env vars) |

#### MCP Connection Config — Per-Agent Format

Each Agent implementation reads MCP server connections from its own config format. AIB generates the correct format per agent and places it in the agent's service directory.

| Agent Type | Config File | Key Fields |
|---|---|---|
| Claude Code | `.mcp/mcp.json` | `mcpServers.{name}.url`, `mcpServers.{name}.transport` |
| Codex | `codex.json` / env vars | Implementation-specific |
| Custom Agent | `config.yaml` / env vars | `mcp_servers[].url`, `mcp_servers[].transport` |

- Transport is always `streamable_http` for Cloud Run (stdio is not supported)
- URLs resolve differently per environment: local → `http://localhost:{port}/{path}`, Cloud Run → `https://{service}.run.app`
- Config files are generated into each service directory so containers can include them at build time

#### Authentication & IAM
- Agent → MCP: ID Token with `roles/run.invoker` on the MCP service
- Private services: `--no-allow-unauthenticated` (default)
- IAM bindings generated per connection edge in topology

#### What AIB Does NOT Generate
- Application code or MCP client implementation (developer responsibility)
- API keys or secrets (managed externally via Secret Manager)
- VPC Connector config (infrastructure-level, out of scope for v1)

#### Deploy Pipeline (target state)
```
workspace.yaml  ──→  aib deploy plan   ──→  Show: services, connections, env vars, IAM
                ──→  aib deploy apply  ──→  Per service:
                                              1. Build container (docker build or Cloud Build)
                                              2. Push to Artifact Registry
                                              3. gcloud run deploy (env vars, IAM, concurrency)
                                              4. Bind IAM invoker roles for connection edges
```

#### Key Constraint
- `service_ref` resolution differs by environment:
  - Local: `http://localhost:{gateway_port}/{mount_path}`
  - Cloud Run: `https://{service-name}-{hash}.{region}.run.app`
- This resolution is the core job of `aib deploy plan` — it maps topology edges to concrete URLs

#### services.yaml Deprecation Plan
`services.yaml` is a local-only intermediate generated from `workspace.yaml`. It adds no information that cannot be derived:
- Namespaced IDs (`agent-py/app`) are computed from `services_namespace` + `id`
- Absolute `cwd` is computed from repo `path` + relative `cwd`
- All runtime defaults (health, restart, concurrency, auth, path_rewrite) are already hardcoded in `AIBConfigLoader` with `??` fallbacks

**Target state**: Gateway/Supervisor read `workspace.yaml` directly. `AIBConfigLoader` is extended to accept workspace format (repos with inline services) and flatten + resolve internally. `services.yaml` generation is removed from `WorkspaceSyncer`. The `.aib/generated/runtime/connections/` directory remains for injecting resolved connection URLs into Agent processes.

## Change Policy

### When modifying `services.yaml` schema
1. Update decode + validation in `AIBConfig`
2. Reflect changes in `AIBCore` models
3. Update at least one test (Config or E2E-equivalent)
4. Update docs

### When modifying Gateway or Supervisor
- Never change one without verifying consistency with the other
- Failure logs must include `service_id`, `action`, and `reason`
- Gateway uses `NIOAsyncChannel` — never use `ChannelInboundHandler` or `ChannelHandlerContext` directly
- All channel I/O must go through `NIOAsyncChannelOutboundWriter` — never access `context.channel` from async contexts
- `DevGateway` lifecycle is managed by `Mutex<LifecyclePhase>` (idle → starting → running → stopped) — all transitions must be atomic

### When modifying App UI
- System/runtime errors and request-level errors must have separate display paths
- Inspector shows selection details only — never use it as the primary log/error surface

## Specifications
- Runtime spec: `docs/cloud-run-aligned-local-runtime-spec.md`
- CLI spec: `docs/aib-workspace-cli-spec.md`
- App spec: `docs/agents-in-black-app-v1-spec.md`
