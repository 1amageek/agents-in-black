# Context Propagation Specification

## Overview

AIB agents run on Cloud Run as independent HTTP services. Clients need to send user identity and tenant information alongside messages. This context must reach MCP servers for data scoping, but agents themselves must remain context-free.

This document defines how context flows through the system and why `fetch`-based streaming was chosen over `EventSource`.

## Transport Decision: `fetch` over `EventSource`

### Why not EventSource

`EventSource` is the browser-native API for Server-Sent Events. It provides automatic reconnection and `Last-Event-ID` tracking. However, it has critical limitations for this use case:

| Constraint | Impact |
|---|---|
| **GET only** | Cannot send a request body. Context (userId, orgId, token) must go in the URL query string. |
| **No custom headers** | Cannot set `Authorization` header. Token must be exposed in the URL. |
| **URL length limits** | Browsers enforce 2048–8192 character limits. Context size is bounded. |
| **Security exposure** | URL parameters appear in access logs, browser history, referrer headers, and proxy caches. Putting tokens or user IDs in URLs is a security risk. |

### Why fetch

`fetch` with `ReadableStream` solves all of the above:

```typescript
const res = await fetch("/chat", {
  method: "POST",
  headers: {
    "Content-Type": "application/json",
    "Authorization": "Bearer <token>"
  },
  body: JSON.stringify({
    message: "user message",
    context: { userId: "u1", orgId: "o1" }
  }),
  signal: abortController.signal
});

const reader = res.body.getReader();
// Read SSE chunks from the stream
```

| Capability | fetch |
|---|---|
| POST with JSON body | Yes |
| Authorization header | Yes |
| Context in body (not URL) | Yes |
| SSE response streaming | Yes, via `ReadableStream` |
| Request cancellation | `AbortController` |
| Cloud Run compatible | Yes |

### Trade-off: No automatic reconnection

`EventSource` reconnects automatically on connection loss and sends `Last-Event-ID` to resume. `fetch` does not.

**Mitigation**: Implement retry logic in the client. The server includes `id:` fields in SSE events, and the client tracks the last received ID. On disconnection, the client retries with the last ID in the request body.

This is a small amount of client code in exchange for secure, flexible context transmission.

## Context Structure

Context is a JSON object sent in the request body under the `"context"` key:

```json
{
  "message": "user message",
  "context": {
    "userId": "user_xxx",
    "orgId": "org_xxx",
    "conversationId": "conv_xxx"
  }
}
```

The schema is defined per workspace using JSON Schema (`SharedContextSchema`). The fields are user-configurable via the AIB App Canvas.

## Architecture: Middleware Pattern (Cloud Run First)

Context propagation is handled by **agent-side middleware**, not by a centralized proxy. This ensures identical behavior in local development and Cloud Run production.

```
Client
  │  POST /chat { message, context }
  ▼
Agent (Cloud Run Service)
  │
  ├─ HTTP Middleware
  │   1. Parse body, extract "context"
  │   2. Store in request-scoped storage
  │   3. Pass cleaned body (without "context") to handler
  │
  ├─ Agent Logic (context-free)
  │   - Receives only { message }
  │   - Performs inference, streams SSE response
  │   - Issues tool calls when needed
  │
  ├─ MCP Client Middleware
  │   1. Read context from request-scoped storage
  │   2. Inject as X-Context header
  │   3. Forward tool call to MCP server
  │
  ▼
MCP Server (Cloud Run Service)
  │  Reads X-Context header
  │  Scopes data access by userId / orgId
  ▼
External Systems (DB / API)
```

### Why middleware, not proxy

A centralized proxy (Gateway) only exists in local development. On Cloud Run, each service is independent — there is no proxy between client and agent, or between agent and MCP.

If context propagation lived in the proxy:
- It would work locally but fail in production.
- Local and production behavior would diverge, hiding bugs.

With middleware embedded in the agent:
- The same code runs in both environments.
- Deploy and it works. No extra infrastructure.

### Request-scoped storage per runtime

| Runtime | Storage Mechanism |
|---|---|
| Node.js | `AsyncLocalStorage` |
| Python | `contextvars.ContextVar` |
| Swift | `@TaskLocal` |
| Deno | Per-request `Map` keyed by request ID |

These are zero-cost abstractions that scope context to the current request without global state.

## MCP Context Injection

When the agent calls an MCP server, context is injected as a single HTTP header:

```http
POST /mcp/tool HTTP/1.1
Content-Type: application/json
X-Context: {"userId":"user_xxx","orgId":"org_xxx"}

{ "jsonrpc": "2.0", "method": "tools/call", ... }
```

The MCP server reads `X-Context` to scope its data access. The agent code never constructs or reads this header — the MCP client middleware handles it transparently.

## SSE Response Format

The agent responds with `text/event-stream`:

```http
HTTP/1.1 200 OK
Content-Type: text/event-stream
Cache-Control: no-cache

data: {"token": "Hello"}

data: {"token": " world"}

: heartbeat

data: [DONE]

```

- Each event is delimited by `\n\n`
- `data:` carries the payload
- `: heartbeat` is a comment line to keep the connection alive (Cloud Run timeout prevention)
- `id:` can be included for client-side resume tracking

## Design Principles

| Principle | Rationale |
|---|---|
| **Cloud Run first** | Design for production. Local dev must match production behavior. |
| **Agent is context-free** | Agent code never accesses userId or orgId. Middleware handles it. |
| **No centralized proxy in production** | Each Cloud Run service is independent. Context propagation is the agent's responsibility. |
| **fetch, not EventSource** | Secure context transmission via POST body and Authorization header. |
| **Single X-Context header for MCP** | Simple, flexible, no field-name mapping needed. MCP server parses one header. |
| **Middleware is generated by AIB** | Agent templates include context middleware. Developers don't write it. |
