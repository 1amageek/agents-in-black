# AgentsInBlack

AgentsInBlack (AIB) is a workspace-first local runtime for developing Agents and MCP services across multiple independent repositories.

It provides:
- single-port local access via `DevGateway`
- multi-process orchestration via `DevSupervisor`
- multi-runtime support (Swift / Node / Deno / Python discovery)
- workspace composition of repo-owned service manifests

## Current Status (v1 prototype)

Implemented:
- `aib init` (workspace bootstrap + repo discovery)
- `aib workspace list|scan|sync`
- `aib emulator start|validate|status|stop` (runtime wrapper)
- repo manifest composition to generated `.aib/services.yaml`
- reverse proxy + supervisor runtime (`aib-dev` internals)

Planned / partial:
- `aib deploy plan|apply` (CLI surface exists; apply is not implemented)
- `aib emulator logs|reload`
- graceful shutdown hardening (`Ctrl-C` exit path and `emulator stop` have known issues)

## Workspace Model

AIB manages a **workspace**, not project initialization.

- each Agent/MCP repo remains an independent git repository
- each repo may define its own manifest (`.aib/services.yaml` or `aib.services.yaml`)
- AIB discovers repos, composes manifests, and runs them together locally

Generated workspace files:
- `.aib/workspace.yaml`
- `.aib/services.yaml` (generated local runtime config)
- `.aib/state/`
- `.aib/logs/`

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
