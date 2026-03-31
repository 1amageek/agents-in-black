# AgentsInBlack

AgentsInBlack (AIB) is a workspace-first local runtime for developing Agents and MCP services across multiple independent repositories.

It provides:
- single-port local access via `DevGateway`
- multi-process orchestration via `DevSupervisor`
- multi-runtime support (Swift / Node / Deno / Python discovery)
- workspace-level service configuration (`.aib/` at workspace root only)
- fast local Node execution via `convenience` mode
- local agent execution via Claude Code CLI

## Current Status (v1 prototype)

Implemented:
- `aib init` (workspace bootstrap + repo discovery)
- `aib workspace list|scan|sync`
- `aib emulator start|validate|status|stop` (runtime wrapper)
- workspace-level `.aib/workspace.yaml` generation
- reverse proxy + supervisor runtime (`aib-dev` internals)

Planned / partial:
- `aib deploy plan|apply` (CLI surface exists; apply is not implemented)
- `aib emulator logs|reload`
- graceful shutdown hardening (`Ctrl-C` exit path and `emulator stop` have known issues)

## Workspace Model

AIB manages a **workspace**, not project initialization.

- `.aib/` exists **only at the workspace root** — individual repositories are never invaded
- Each Agent/MCP repo remains an independent git repository with no AIB-specific files
- AIB discovers repos from native build files (`Package.swift`, `package.json`, etc.)
- All service configuration is managed in the workspace-level `.aib/workspace.yaml`

Workspace directory structure:
- `.aib/workspace.yaml` — discovered repos + local runtime config (source of truth for emulator)
- `.aib/generated/` — runtime artifacts (connection files, etc.)
- `.aib/state/` — runtime state (PID files, etc.)
- `.aib/logs/` — service logs

## Build

```bash
swift build
swift test
```

Binaries:
- `./.build/debug/aib`
- `./.build/debug/aib-dev` (legacy compatibility / internal runtime entry)

## Quick Start (Demo)

A demo workspace is included at `/Users/1amageek/Desktop/agents-in-black/demo` with:
- Python agent repo (`agent-py`)
- Node MCP repo (`mcp-node`)

```bash
cd /Users/1amageek/Desktop/agents-in-black/demo
../.build/debug/aib init --force
../.build/debug/aib workspace list
../.build/debug/aib emulator start --gateway-port 18080
```

`local` targets default to `buildMode: convenience`, which runs Node MCP services as
host processes for fast iteration. Use `buildMode: strict` when you explicitly want
Cloud Run-aligned containerized validation.

Test endpoints:

```bash
curl -sS 'http://127.0.0.1:18080/agents/py/hello?x=1'
curl -sS -X POST 'http://127.0.0.1:18080/mcp/node/echo' -d 'ping'
```

## Documentation

- `/Users/1amageek/Desktop/agents-in-black/docs/cloud-run-aligned-local-runtime-spec.md`
- `/Users/1amageek/Desktop/agents-in-black/docs/aib-workspace-cli-spec.md`
- `/Users/1amageek/Desktop/agents-in-black/demo/README.md`

## Notes

This repository is currently a prototype implementation focused on local emulator behavior and workspace orchestration semantics.

Local execution modes:
- `convenience`: default for `.aib/targets/local.yaml`; fast host-process execution for local development
- `strict`: slower containerized execution intended for Cloud Run-aligned validation

Local agent services are not containerized. They run through Claude Code CLI and are
served by the local handler registered in `AIBCore`.
