# AgentsInBlack Workspace-Aware CLI Specification (v1)

## Overview

AgentsInBlack (AIB) is a multi-repo workspace orchestrator for Agent/MCP development.
Each Agent/MCP repository remains an independent Git repository. AIB manages only the local workspace orchestration layer.

## Core Principles

- AIB manages the workspace, not project initialization.
- Repositories are discovered and registered; repo files are not modified by default.
- Local execution is composed from repo-provided manifests and workspace-generated defaults.
- Services are language-agnostic HTTP units.

## Commands

### `aib init`

Initializes a workspace at the current directory.

Responsibilities:
- Create `.aib/` workspace directory structure
- Discover repositories by scanning for `.git`
- Detect runtime/framework hints (`swift`, `node`, `deno`, `python`)
- Detect repo service manifests (`.aib/services.yaml`, `aib.services.yaml`)
- Generate `.aib/workspace.yaml`
- Generate composed local runtime config `.aib/services.yaml`

Options:
- `--scan <path>`: scan root (default current directory)
- `--no-scan`: initialize empty workspace config
- `--force`: overwrite existing workspace config

### `aib workspace list`

Lists discovered repositories and status.

### `aib workspace scan`

Re-scan workspace repositories and refresh `.aib/workspace.yaml`, then regenerate `.aib/services.yaml`.

### `aib workspace sync`

Regenerate `.aib/services.yaml` from `.aib/workspace.yaml` and repo manifests.

### `aib emulator start`

Runs the local runtime using generated `.aib/services.yaml`.
Internally wraps the existing DevGateway + DevSupervisor runtime.

### `aib emulator validate`

Validates generated `.aib/services.yaml` using existing runtime config validation.

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
  services.yaml              # generated local runtime config
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
- Repo service definitions: repo-owned manifests (`<repo>/.aib/services.yaml` etc.)
- Local runtime config (`.aib/services.yaml`) is generated from the above

## Repo Status Classification

- `managed`: repo manifest exists and is readable
- `discoverable`: runtime/framework detected, no repo manifest
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

Workspace-generated service IDs are namespaced as:

- `<repoName>/<serviceID>` for managed repo manifests
- `<repoName>/main` for discoverable repos with selected command

This avoids collisions across independent repositories.

## Generated Local Service Defaults (Discoverable repos)

When no repo manifest exists but a command candidate is selected, AIB may generate a default service with:

- `mount_path`: `/<repoName>`
- `port`: `0`
- `watch_mode`: runtime default (`swift=external`, others usually `internal`)
- default health/restart/concurrency values

## Non-goals (v1)

- Project initialization inside individual Agent/MCP repositories
- Editing repo `Package.swift` / `package.json` / source files
- Forcing framework-specific application structure
- Full Cloud Run deploy implementation
