import Foundation

/// Code snippets for the AIB Context middleware generated into agent templates.
///
/// Each runtime gets a self-contained module that:
/// 1. Extracts `"context"` from the JSON request body
/// 2. Stores it in request-scoped storage
/// 3. Provides `aibFetch` that auto-injects `X-Context` header on outgoing MCP calls
/// 4. Agent application code never touches context
enum ContextMiddlewareSnippets {

    // MARK: - Node.js (TypeScript)

    static let nodeTS = """
    import { AsyncLocalStorage } from "node:async_hooks";

    type Context = Record<string, unknown>;
    const storage = new AsyncLocalStorage<Context>();

    /**
     * Hono / Express middleware.
     * Extracts "context" from the JSON body and stores it for the request lifecycle.
     * The handler receives the body without "context".
     */
    export function aibContext() {
      return async (c: any, next: () => Promise<void>) => {
        let context: Context = {};
        try {
          const body = await c.req.json();
          if (body && typeof body === "object" && "context" in body) {
            const { context: ctx, ...rest } = body;
            context = ctx ?? {};
            c.req._aibCleanBody = rest;
          }
        } catch {
          // Not JSON — proceed without context.
        }
        await storage.run(context, next);
      };
    }

    /** Get the current request's context. */
    export function getContext(): Context {
      return storage.getStore() ?? {};
    }

    /** Get the cleaned body (context removed). */
    export async function getCleanBody(c: any): Promise<unknown> {
      if (c.req._aibCleanBody !== undefined) return c.req._aibCleanBody;
      return c.req.json();
    }

    /**
     * fetch wrapper that auto-injects X-Context header.
     * Use this for all outgoing MCP / service-to-service calls.
     */
    export async function aibFetch(url: string | URL, init?: RequestInit): Promise<Response> {
      const ctx = getContext();
      const headers = new Headers(init?.headers);
      if (Object.keys(ctx).length > 0) {
        headers.set("X-Context", JSON.stringify(ctx));
      }
      return fetch(url, { ...init, headers });
    }
    """

    // MARK: - Deno (TypeScript)

    static let denoTS = """
    type Context = Record<string, unknown>;
    const _store = new Map<string, Context>();

    /**
     * Hono middleware for Deno.
     * Extracts "context" from the JSON body and stores it for the request lifecycle.
     */
    export function aibContext() {
      return async (c: any, next: () => Promise<void>) => {
        const id = crypto.randomUUID();
        c.set("_aibReqId", id);
        let context: Context = {};
        try {
          const body = await c.req.json();
          if (body && typeof body === "object" && "context" in body) {
            const { context: ctx, ...rest } = body;
            context = ctx ?? {};
            c.req._aibCleanBody = rest;
          }
        } catch {
          // Not JSON — proceed without context.
        }
        _store.set(id, context);
        try {
          await next();
        } finally {
          _store.delete(id);
        }
      };
    }

    /** Get the current request's context. Pass the Hono context. */
    export function getContext(c: any): Context {
      return _store.get(c.get("_aibReqId")) ?? {};
    }

    /** Get the cleaned body (context removed). */
    export async function getCleanBody(c: any): Promise<unknown> {
      if (c.req._aibCleanBody !== undefined) return c.req._aibCleanBody;
      return c.req.json();
    }

    /**
     * fetch wrapper that auto-injects X-Context header.
     * Use this for all outgoing MCP / service-to-service calls.
     */
    export async function aibFetch(c: any, url: string | URL, init?: RequestInit): Promise<Response> {
      const ctx = getContext(c);
      const headers = new Headers(init?.headers);
      if (Object.keys(ctx).length > 0) {
        headers.set("X-Context", JSON.stringify(ctx));
      }
      return fetch(url, { ...init, headers });
    }
    """

    // MARK: - Python

    static let python = #"""
    """AIB Context Propagation Middleware."""

    import contextvars
    import json
    from typing import Any

    _aib_context: contextvars.ContextVar[dict[str, Any]] = contextvars.ContextVar(
        "aib_context", default={}
    )


    def get_context() -> dict[str, Any]:
        """Get the current request's context."""
        return _aib_context.get()


    def extract_context(body: dict[str, Any]) -> tuple[dict[str, Any], dict[str, Any]]:
        """Extract 'context' from body. Returns (context, cleaned_body)."""
        body = dict(body)
        context = body.pop("context", {})
        return context, body


    def aib_context_middleware(app):
        """FastAPI / Starlette middleware that extracts context from request body."""
        from starlette.middleware.base import BaseHTTPMiddleware
        from starlette.requests import Request
        from starlette.responses import Response

        class _Middleware(BaseHTTPMiddleware):
            async def dispatch(self, request: Request, call_next) -> Response:
                if request.method in ("POST", "PUT", "PATCH"):
                    try:
                        body = await request.json()
                        if isinstance(body, dict) and "context" in body:
                            context, cleaned = extract_context(body)
                            _aib_context.set(context)
                            request.state.aib_clean_body = cleaned
                    except Exception:
                        pass
                return await call_next(request)

        app.add_middleware(_Middleware)


    async def aib_fetch(
        url: str,
        *,
        method: str = "POST",
        headers: dict[str, str] | None = None,
        json_body: Any = None,
    ):
        """HTTP client that auto-injects X-Context header for MCP calls."""
        import httpx

        h = dict(headers or {})
        ctx = get_context()
        if ctx:
            h["X-Context"] = json.dumps(ctx)
        async with httpx.AsyncClient() as client:
            return await client.request(method, url, headers=h, json=json_body)
    """#

    // MARK: - Swift (Hummingbird)

    static let swift = """
    import Foundation
    import Hummingbird
    import NIOCore
    #if canImport(FoundationNetworking)
    import FoundationNetworking
    #endif

    /// Request-scoped context storage using TaskLocal.
    public enum AIBContext {
        @TaskLocal public static var current: [String: String] = [:]
    }

    /// Hummingbird middleware that extracts "context" from the JSON body,
    /// stores it in TaskLocal, and forwards the cleaned body to the handler.
    /// Agent handlers never see context — it is fully transparent.
    public struct AIBContextMiddleware<Context: RequestContext>: RouterMiddleware {
        public init() {}

        public func handle(
            _ request: Request,
            context: Context,
            next: (Request, Context) async throws -> Response
        ) async throws -> Response {
            let body = try await request.body.collect(upTo: 1_048_576)
            let data = Data(buffer: body)

            guard !data.isEmpty,
                  var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let contextObj = json.removeValue(forKey: "context") as? [String: Any]
            else {
                // No context in body — pass through unchanged.
                return try await next(request, context)
            }

            let ctx = contextObj.compactMapValues { $0 as? String }
            let cleaned = try JSONSerialization.data(withJSONObject: json)
            var cleanedRequest = request
            cleanedRequest.body = .init(byteBuffer: ByteBuffer(data: cleaned))

            return try await AIBContext.$current.withValue(ctx) {
                try await next(cleanedRequest, context)
            }
        }
    }

    /// URL request wrapper that auto-injects X-Context header.
    /// Use this for all outgoing MCP / service-to-service calls.
    public func aibFetch(
        url: URL,
        method: String = "POST",
        headers: [String: String] = [:],
        body: Data? = nil
    ) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let ctx = AIBContext.current
        if !ctx.isEmpty, let json = try? JSONSerialization.data(withJSONObject: ctx) {
            request.setValue(String(data: json, encoding: .utf8), forHTTPHeaderField: "X-Context")
        }
        request.httpBody = body
        return try await URLSession.shared.data(for: request)
    }
    """
}
