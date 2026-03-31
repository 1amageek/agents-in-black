# AgentsInBlack Workspace-Aware CLI Specification (v1)

## Overview

AgentsInBlack (AIB) is a multi-repo workspace orchestrator for Agent/MCP development.
Each Agent/MCP repository remains an independent Git repository. AIB manages only the local workspace orchestration layer.

## Core Principles

- AIB manages the workspace, not project initialization.
- `.aib/` exists **only at the workspace root**. Individual repositories are never invaded with AIB-specific files or directories.
- Repositories are discovered by scanning for native build files (`Package.swift`, `package.json`, `deno.json`, `pyproject.toml`, etc.).
- All service definitions are managed entirely within the workspace-level `.aib/workspace.yaml`.
- Services are language-agnostic HTTP units.

## Commands

### `aib init`

Initializes a workspace at the current directory.

Responsibilities:
- Create `.aib/` workspace directory structure (only at workspace root)
- Discover repositories by scanning for `.git`
- Detect runtime/framework from native build files (`Package.swift`, `package.json`, `deno.json`, `pyproject.toml`, etc.)
- Generate `.aib/workspace.yaml` with discovered repo metadata
- Resolve runtime service config from `.aib/workspace.yaml`

Options:
- `--scan <path>`: scan root (default current directory)
- `--no-scan`: initialize empty workspace config
- `--force`: overwrite existing workspace config

### `aib workspace list`

Lists discovered repositories and status.

### `aib workspace scan`

Re-scan workspace repositories and refresh `.aib/workspace.yaml`.

### `aib workspace sync`

Resolve runtime service config from `.aib/workspace.yaml` and refresh generated runtime artifacts.

### `aib emulator start`

Runs the local runtime using generated `.aib/workspace.yaml`.
Internally wraps the existing DevGateway + DevSupervisor runtime.

For `local` targets:
- default `buildMode` is `convenience`
- Node MCP/services run as host processes for fast local iteration
- agent services run via Claude Code CLI, not local containers

### `aib emulator validate`

Validates generated `.aib/workspace.yaml` using existing runtime config validation.

### `aib emulator status`

Best-effort foreground runtime status using `.aib/state/emulator.pid`.

### `aib emulator stop`

Sends SIGTERM to PID recorded in `.aib/state/emulator.pid`.

### `aib deploy plan|diff|apply`

Reserved for Cloud Run deployment workflows.
`plan/diff` may emit workspace summary in v1; `apply` can remain unimplemented with explicit error.

## Workspace Layout

```text
.aib/
  workspace.yaml
  environments/
    local.yaml
    staging.yaml
    prod.yaml
  state/
    emulator.pid
  logs/
```

## Workspace Source of Truth

- Workspace orchestration config: `.aib/workspace.yaml`
- Local runtime config: resolved from `.aib/workspace.yaml`
- **No per-repo manifests**: `.aib/` does not exist inside individual repositories

## Local Target Source Credentials

Strict local builds that resolve private Git dependencies must declare explicit source
credentials in `.aib/targets/local.yaml`.

The generated `local` target template defaults to:

```yaml
buildMode: convenience
```

Switch to `strict` only when Cloud Run-aligned containerized validation is required.

```yaml
sourceCredentials:
  - type: ssh
    host: github.com
    localPrivateKeyPath: /Users/example/.ssh/id_ed25519
    localKnownHostsPath: /Users/example/.ssh/known_hosts
    localPrivateKeyPassphraseEnv: AIB_GITHUB_KEY_PASSPHRASE
```

If `localPrivateKeyPassphraseEnv` is set, AIB reads that environment variable on the
host, creates a temporary decrypted key only for the build-preparation lifecycle, and
mounts that ephemeral copy into the isolated build container. The container never prompts
for a passphrase.

## Repo Status Classification

- `discoverable`: runtime/framework detected from native build files
- `unresolved`: repo detected but no reliable command candidate
- `ignored`: explicitly disabled/ignored

## Multi-Language Detection Model

### Runtime adapters

- Swift
- Node
- Deno
- Python

### Framework profiles (heuristic)

Examples (non-exhaustive):
- Swift: Vapor, Hummingbird
- Node: Express, Fastify, NestJS, Next.js, Hono
- Deno: Fresh, Oak, Hono
- Python: FastAPI, Flask, Django, Starlette

## Service Namespacing

Service IDs are namespaced as `<repoName>/<serviceID>` to avoid collisions across independent repositories.

For auto-discovered repos, the default service ID is `<repoName>/main`.

## Generated Local Service Defaults

When a repo is discovered and a command candidate is selected, AIB generates a default service entry in `.aib/workspace.yaml` with:

- `id`: `<repoName>/main`
- `mount_path`: `/<repoName>`
- `port`: `0`
- `watch_mode`: runtime default (`swift=external`, others usually `internal`)
- default health/restart/concurrency values

Users can customize service configuration by editing `.aib/workspace.yaml` directly.

## Non-goals (v1)

- Creating `.aib/` directories inside individual repositories
- Editing repo `Package.swift` / `package.json` / source files
- Forcing framework-specific application structure
- Full Cloud Run deploy implementation
