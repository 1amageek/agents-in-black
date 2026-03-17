import Foundation

// MARK: - Protocol

/// Protocol for scaffolding new project directories from templates.
public protocol ProjectTemplate: Sendable {
    var runtime: RuntimeKind { get }
    var framework: FrameworkKind { get }
    var displayName: String { get }

    /// Create project files at the given directory.
    /// - Parameters:
    ///   - directory: Target directory (will be created if it doesn't exist).
    ///   - serviceName: Name for the service (used in manifests).
    func scaffold(at directory: URL, serviceName: String) throws
}

// MARK: - Registry

public enum ProjectTemplateRegistry {
    public static let templates: [any ProjectTemplate] = [
        // Swift
        SwiftHummingbirdTemplate(),
        SwiftVaporTemplate(),
        SwiftPlainTemplate(),
        // Node
        NodeHonoTemplate(),
        NodeExpressTemplate(),
        NodeFastifyTemplate(),
        NodePlainTemplate(),
        // Python
        PythonFastAPITemplate(),
        PythonFlaskTemplate(),
        PythonPlainTemplate(),
        // Deno
        DenoHonoTemplate(),
        DenoOakTemplate(),
        DenoFreshTemplate(),
        DenoPlainTemplate(),
    ]

    public static func templates(for runtime: RuntimeKind) -> [any ProjectTemplate] {
        templates.filter { $0.runtime == runtime }
    }

    public static func template(for runtime: RuntimeKind, framework: FrameworkKind) -> (any ProjectTemplate)? {
        templates.first { $0.runtime == runtime && $0.framework == framework }
    }

    /// All supported runtimes that have at least one template.
    public static var supportedRuntimes: [RuntimeKind] {
        [.swift, .node, .python, .deno]
    }
}

// MARK: - Helpers

private func ensureDirectory(at url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
}

private func writeFile(at url: URL, content: String) throws {
    try content.write(to: url, atomically: true, encoding: .utf8)
}

// MARK: - Swift Templates

struct SwiftHummingbirdTemplate: ProjectTemplate {
    let runtime: RuntimeKind = .swift
    let framework: FrameworkKind = .hummingbird
    let displayName = "Hummingbird"

    func scaffold(at directory: URL, serviceName: String) throws {
        try ensureDirectory(at: directory.appendingPathComponent("Sources"))

        let packageSwift = """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(
            name: "\(serviceName)",
            platforms: [.macOS(.v14)],
            dependencies: [
                .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
            ],
            targets: [
                .executableTarget(
                    name: "\(serviceName)",
                    dependencies: [
                        .product(name: "Hummingbird", package: "hummingbird"),
                    ],
                    path: "Sources"
                ),
            ]
        )
        """

        let main = """
        import Hummingbird
        import Foundation

        @main
        struct App {
            static func main() async throws {
                let port = ProcessInfo.processInfo.environment["PORT"].flatMap(Int.init) ?? 8080
                let router = Router()

                // Context middleware — extracts "context" from body, invisible to handlers.
                router.add(middleware: AIBContextMiddleware())

                router.get("/") { _, _ in
                    "Hello from \\(serviceName)!"
                }

                router.get("/health") { _, _ in
                    "ok"
                }

                router.post("/chat") { request, _ -> Response in
                    // Handler receives cleaned body (no "context").
                    // Use aibFetch() for MCP calls — X-Context is injected automatically.
                    let body = try await request.body.collect(upTo: 1_048_576)
                    return Response(status: .ok, body: .init(byteBuffer: body))
                }

                let app = Application(router: router, configuration: .init(address: .hostname("0.0.0.0", port: port)))
                try await app.runService()
            }
        }
        """

        try writeFile(at: directory.appendingPathComponent("Package.swift"), content: packageSwift)
        try writeFile(at: directory.appendingPathComponent("Sources/App.swift"), content: main)
        try writeFile(at: directory.appendingPathComponent("Sources/AIBContext.swift"), content: ContextMiddlewareSnippets.swift)
        try writeFile(at: directory.appendingPathComponent(".gitignore"), content: swiftGitignore)
    }
}

struct SwiftVaporTemplate: ProjectTemplate {
    let runtime: RuntimeKind = .swift
    let framework: FrameworkKind = .vapor
    let displayName = "Vapor"

    func scaffold(at directory: URL, serviceName: String) throws {
        try ensureDirectory(at: directory.appendingPathComponent("Sources"))

        let packageSwift = """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(
            name: "\(serviceName)",
            platforms: [.macOS(.v14)],
            dependencies: [
                .package(url: "https://github.com/vapor/vapor.git", from: "4.99.0"),
            ],
            targets: [
                .executableTarget(
                    name: "\(serviceName)",
                    dependencies: [
                        .product(name: "Vapor", package: "vapor"),
                    ],
                    path: "Sources"
                ),
            ]
        )
        """

        let main = """
        import Vapor

        @main
        struct App {
            static func main() async throws {
                let app = try await Application.make()
                let port = ProcessInfo.processInfo.environment["PORT"].flatMap(Int.init) ?? 8080
                app.http.server.configuration.port = port
                app.http.server.configuration.hostname = "0.0.0.0"

                app.get { req in
                    "Hello from \\(serviceName)!"
                }

                app.get("health") { req in
                    "ok"
                }

                try await app.execute()
            }
        }
        """

        try writeFile(at: directory.appendingPathComponent("Package.swift"), content: packageSwift)
        try writeFile(at: directory.appendingPathComponent("Sources/App.swift"), content: main)
        try writeFile(at: directory.appendingPathComponent(".gitignore"), content: swiftGitignore)
    }
}

struct SwiftPlainTemplate: ProjectTemplate {
    let runtime: RuntimeKind = .swift
    let framework: FrameworkKind = .plain
    let displayName = "Plain (no framework)"

    func scaffold(at directory: URL, serviceName: String) throws {
        try ensureDirectory(at: directory.appendingPathComponent("Sources"))

        let packageSwift = """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(
            name: "\(serviceName)",
            platforms: [.macOS(.v14)],
            targets: [
                .executableTarget(
                    name: "\(serviceName)",
                    path: "Sources"
                ),
            ]
        )
        """

        let main = """
        import Foundation
        #if canImport(FoundationNetworking)
        import FoundationNetworking
        #endif

        @main
        struct App {
            static func main() {
                let port = ProcessInfo.processInfo.environment["PORT"] ?? "8080"
                print("Starting \\(serviceName) on port \\(port)")
            }
        }
        """

        try writeFile(at: directory.appendingPathComponent("Package.swift"), content: packageSwift)
        try writeFile(at: directory.appendingPathComponent("Sources/App.swift"), content: main)
        try writeFile(at: directory.appendingPathComponent(".gitignore"), content: swiftGitignore)
    }
}

private let swiftGitignore = """
.DS_Store
.build/
.swiftpm/
Package.resolved
*.xcodeproj
xcuserdata/
"""

// MARK: - Node Templates

struct NodeHonoTemplate: ProjectTemplate {
    let runtime: RuntimeKind = .node
    let framework: FrameworkKind = .hono
    let displayName = "Hono"

    func scaffold(at directory: URL, serviceName: String) throws {
        try ensureDirectory(at: directory.appendingPathComponent("src"))

        let packageJSON = """
        {
          "name": "\(serviceName)",
          "version": "1.0.0",
          "type": "module",
          "scripts": {
            "start": "node dist/index.js",
            "dev": "tsx watch src/index.ts",
            "build": "tsc"
          },
          "dependencies": {
            "hono": "^4.0.0",
            "@hono/node-server": "^1.0.0"
          },
          "devDependencies": {
            "tsx": "^4.0.0",
            "typescript": "^5.0.0"
          }
        }
        """

        let tsconfig = """
        {
          "compilerOptions": {
            "target": "ES2022",
            "module": "ESNext",
            "moduleResolution": "bundler",
            "outDir": "dist",
            "strict": true,
            "esModuleInterop": true,
            "skipLibCheck": true
          },
          "include": ["src"]
        }
        """

        let index = """
        import { Hono } from "hono";
        import { serve } from "@hono/node-server";
        import { aibContext, getCleanBody } from "./aib-context.js";

        const app = new Hono();

        // Context middleware — extracts "context" from body, invisible to handlers.
        app.use("*", aibContext());

        app.get("/", (c) => c.text("Hello from \(serviceName)!"));

        app.get("/health", (c) => c.text("ok"));

        app.post("/chat", async (c) => {
          const body = await getCleanBody(c);
          return c.json({ message: "received", body });
        });

        const port = Number(process.env.PORT) || 8080;
        console.log(`Starting \(serviceName) on port ${port}`);
        serve({ fetch: app.fetch, port });
        """

        try writeFile(at: directory.appendingPathComponent("package.json"), content: packageJSON)
        try writeFile(at: directory.appendingPathComponent("tsconfig.json"), content: tsconfig)
        try writeFile(at: directory.appendingPathComponent("src/index.ts"), content: index)
        try writeFile(at: directory.appendingPathComponent("src/aib-context.ts"), content: ContextMiddlewareSnippets.nodeTS)
        try writeFile(at: directory.appendingPathComponent(".gitignore"), content: nodeGitignore)
    }
}

struct NodeExpressTemplate: ProjectTemplate {
    let runtime: RuntimeKind = .node
    let framework: FrameworkKind = .express
    let displayName = "Express"

    func scaffold(at directory: URL, serviceName: String) throws {
        try ensureDirectory(at: directory.appendingPathComponent("src"))

        let packageJSON = """
        {
          "name": "\(serviceName)",
          "version": "1.0.0",
          "type": "module",
          "scripts": {
            "start": "node src/index.js",
            "dev": "node --watch src/index.js"
          },
          "dependencies": {
            "express": "^5.0.0"
          }
        }
        """

        let index = """
        import express from "express";

        const app = express();
        app.use(express.json());

        app.get("/", (req, res) => {
          res.send("Hello from \(serviceName)!");
        });

        app.get("/health", (req, res) => {
          res.send("ok");
        });

        const port = Number(process.env.PORT) || 8080;
        app.listen(port, "0.0.0.0", () => {
          console.log(`Starting \(serviceName) on port ${port}`);
        });
        """

        try writeFile(at: directory.appendingPathComponent("package.json"), content: packageJSON)
        try writeFile(at: directory.appendingPathComponent("src/index.js"), content: index)
        try writeFile(at: directory.appendingPathComponent(".gitignore"), content: nodeGitignore)
    }
}

struct NodeFastifyTemplate: ProjectTemplate {
    let runtime: RuntimeKind = .node
    let framework: FrameworkKind = .fastify
    let displayName = "Fastify"

    func scaffold(at directory: URL, serviceName: String) throws {
        try ensureDirectory(at: directory.appendingPathComponent("src"))

        let packageJSON = """
        {
          "name": "\(serviceName)",
          "version": "1.0.0",
          "type": "module",
          "scripts": {
            "start": "node src/index.js",
            "dev": "node --watch src/index.js"
          },
          "dependencies": {
            "fastify": "^5.0.0"
          }
        }
        """

        let index = """
        import Fastify from "fastify";

        const fastify = Fastify({ logger: true });

        fastify.get("/", async (request, reply) => {
          return "Hello from \(serviceName)!";
        });

        fastify.get("/health", async (request, reply) => {
          return "ok";
        });

        const port = Number(process.env.PORT) || 8080;
        fastify.listen({ port, host: "0.0.0.0" }, (err) => {
          if (err) {
            fastify.log.error(err);
            process.exit(1);
          }
        });
        """

        try writeFile(at: directory.appendingPathComponent("package.json"), content: packageJSON)
        try writeFile(at: directory.appendingPathComponent("src/index.js"), content: index)
        try writeFile(at: directory.appendingPathComponent(".gitignore"), content: nodeGitignore)
    }
}

struct NodePlainTemplate: ProjectTemplate {
    let runtime: RuntimeKind = .node
    let framework: FrameworkKind = .plain
    let displayName = "Plain (no framework)"

    func scaffold(at directory: URL, serviceName: String) throws {
        try ensureDirectory(at: directory.appendingPathComponent("src"))

        let packageJSON = """
        {
          "name": "\(serviceName)",
          "version": "1.0.0",
          "type": "module",
          "scripts": {
            "start": "node src/index.js",
            "dev": "node --watch src/index.js"
          }
        }
        """

        let index = """
        import { createServer } from "node:http";

        const port = Number(process.env.PORT) || 8080;

        const server = createServer((req, res) => {
          if (req.url === "/health") {
            res.writeHead(200).end("ok");
            return;
          }
          res.writeHead(200).end("Hello from \(serviceName)!");
        });

        server.listen(port, "0.0.0.0", () => {
          console.log(`Starting \(serviceName) on port ${port}`);
        });
        """

        try writeFile(at: directory.appendingPathComponent("package.json"), content: packageJSON)
        try writeFile(at: directory.appendingPathComponent("src/index.js"), content: index)
        try writeFile(at: directory.appendingPathComponent(".gitignore"), content: nodeGitignore)
    }
}

private let nodeGitignore = """
.DS_Store
node_modules/
dist/
*.js.map
"""

// MARK: - Python Templates

struct PythonFastAPITemplate: ProjectTemplate {
    let runtime: RuntimeKind = .python
    let framework: FrameworkKind = .fastapi
    let displayName = "FastAPI"

    func scaffold(at directory: URL, serviceName: String) throws {
        try ensureDirectory(at: directory)

        let pyproject = """
        [project]
        name = "\(serviceName)"
        version = "0.1.0"
        requires-python = ">=3.11"
        dependencies = [
            "fastapi>=0.115.0",
            "uvicorn[standard]>=0.30.0",
            "httpx>=0.27.0",
        ]
        """

        let main = """
        import os
        from fastapi import FastAPI, Request
        from aib_context import aib_context_middleware, get_context

        app = FastAPI()

        # Context middleware — extracts "context" from body, invisible to handlers.
        aib_context_middleware(app)

        @app.get("/")
        async def root():
            return {"message": "Hello from \(serviceName)!"}

        @app.get("/health")
        async def health():
            return "ok"

        @app.post("/chat")
        async def chat(request: Request):
            body = getattr(request.state, "aib_clean_body", await request.json())
            return {"message": "received", "body": body}

        if __name__ == "__main__":
            import uvicorn
            port = int(os.environ.get("PORT", "8080"))
            uvicorn.run(app, host="0.0.0.0", port=port)
        """

        try writeFile(at: directory.appendingPathComponent("pyproject.toml"), content: pyproject)
        try writeFile(at: directory.appendingPathComponent("main.py"), content: main)
        try writeFile(at: directory.appendingPathComponent("aib_context.py"), content: ContextMiddlewareSnippets.python)
        try writeFile(at: directory.appendingPathComponent(".gitignore"), content: pythonGitignore)
    }
}

struct PythonFlaskTemplate: ProjectTemplate {
    let runtime: RuntimeKind = .python
    let framework: FrameworkKind = .flask
    let displayName = "Flask"

    func scaffold(at directory: URL, serviceName: String) throws {
        try ensureDirectory(at: directory)

        let pyproject = """
        [project]
        name = "\(serviceName)"
        version = "0.1.0"
        requires-python = ">=3.11"
        dependencies = [
            "flask>=3.0.0",
            "gunicorn>=22.0.0",
        ]
        """

        let main = """
        import os
        from flask import Flask

        app = Flask(__name__)

        @app.route("/")
        def root():
            return "Hello from \(serviceName)!"

        @app.route("/health")
        def health():
            return "ok"

        if __name__ == "__main__":
            port = int(os.environ.get("PORT", "8080"))
            app.run(host="0.0.0.0", port=port)
        """

        try writeFile(at: directory.appendingPathComponent("pyproject.toml"), content: pyproject)
        try writeFile(at: directory.appendingPathComponent("main.py"), content: main)
        try writeFile(at: directory.appendingPathComponent(".gitignore"), content: pythonGitignore)
    }
}

struct PythonPlainTemplate: ProjectTemplate {
    let runtime: RuntimeKind = .python
    let framework: FrameworkKind = .plain
    let displayName = "Plain (no framework)"

    func scaffold(at directory: URL, serviceName: String) throws {
        try ensureDirectory(at: directory)

        let pyproject = """
        [project]
        name = "\(serviceName)"
        version = "0.1.0"
        requires-python = ">=3.11"
        dependencies = []
        """

        let main = """
        import os
        from http.server import HTTPServer, BaseHTTPRequestHandler

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                if self.path == "/health":
                    self.send_response(200)
                    self.end_headers()
                    self.wfile.write(b"ok")
                    return
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b"Hello from \(serviceName)!")

        if __name__ == "__main__":
            port = int(os.environ.get("PORT", "8080"))
            server = HTTPServer(("0.0.0.0", port), Handler)
            print(f"Starting \(serviceName) on port {port}")
            server.serve_forever()
        """

        try writeFile(at: directory.appendingPathComponent("pyproject.toml"), content: pyproject)
        try writeFile(at: directory.appendingPathComponent("main.py"), content: main)
        try writeFile(at: directory.appendingPathComponent(".gitignore"), content: pythonGitignore)
    }
}

private let pythonGitignore = """
.DS_Store
__pycache__/
*.pyc
.venv/
dist/
*.egg-info/
"""

// MARK: - Deno Templates

struct DenoHonoTemplate: ProjectTemplate {
    let runtime: RuntimeKind = .deno
    let framework: FrameworkKind = .hono
    let displayName = "Hono"

    func scaffold(at directory: URL, serviceName: String) throws {
        try ensureDirectory(at: directory)

        let denoJSON = """
        {
          "name": "\(serviceName)",
          "tasks": {
            "dev": "deno run --watch --allow-net --allow-env main.ts",
            "start": "deno run --allow-net --allow-env main.ts"
          },
          "imports": {
            "hono": "jsr:@hono/hono"
          }
        }
        """

        let main = """
        import { Hono } from "hono";
        import { aibContext, getCleanBody } from "./aib-context.ts";

        const app = new Hono();

        // Context middleware — extracts "context" from body, invisible to handlers.
        app.use("*", aibContext());

        app.get("/", (c) => c.text("Hello from \(serviceName)!"));

        app.get("/health", (c) => c.text("ok"));

        app.post("/chat", async (c) => {
          const body = await getCleanBody(c);
          return c.json({ message: "received", body });
        });

        const port = Number(Deno.env.get("PORT")) || 8080;
        console.log(`Starting \(serviceName) on port ${port}`);
        Deno.serve({ port, hostname: "0.0.0.0" }, app.fetch);
        """

        try writeFile(at: directory.appendingPathComponent("deno.json"), content: denoJSON)
        try writeFile(at: directory.appendingPathComponent("main.ts"), content: main)
        try writeFile(at: directory.appendingPathComponent("aib-context.ts"), content: ContextMiddlewareSnippets.denoTS)
        try writeFile(at: directory.appendingPathComponent(".gitignore"), content: denoGitignore)
    }
}

struct DenoOakTemplate: ProjectTemplate {
    let runtime: RuntimeKind = .deno
    let framework: FrameworkKind = .oak
    let displayName = "Oak"

    func scaffold(at directory: URL, serviceName: String) throws {
        try ensureDirectory(at: directory)

        let denoJSON = """
        {
          "name": "\(serviceName)",
          "tasks": {
            "dev": "deno run --watch --allow-net --allow-env main.ts",
            "start": "deno run --allow-net --allow-env main.ts"
          },
          "imports": {
            "@oak/oak": "jsr:@oak/oak"
          }
        }
        """

        let main = """
        import { Application, Router } from "@oak/oak";

        const router = new Router();

        router.get("/", (ctx) => {
          ctx.response.body = "Hello from \(serviceName)!";
        });

        router.get("/health", (ctx) => {
          ctx.response.body = "ok";
        });

        const port = Number(Deno.env.get("PORT")) || 8080;
        const app = new Application();
        app.use(router.routes());
        app.use(router.allowedMethods());

        console.log(`Starting \(serviceName) on port ${port}`);
        await app.listen({ port, hostname: "0.0.0.0" });
        """

        try writeFile(at: directory.appendingPathComponent("deno.json"), content: denoJSON)
        try writeFile(at: directory.appendingPathComponent("main.ts"), content: main)
        try writeFile(at: directory.appendingPathComponent(".gitignore"), content: denoGitignore)
    }
}

struct DenoFreshTemplate: ProjectTemplate {
    let runtime: RuntimeKind = .deno
    let framework: FrameworkKind = .fresh
    let displayName = "Fresh"

    func scaffold(at directory: URL, serviceName: String) throws {
        try ensureDirectory(at: directory)

        let denoJSON = """
        {
          "name": "\(serviceName)",
          "tasks": {
            "dev": "deno run --watch --allow-net --allow-env --allow-read main.ts",
            "start": "deno run --allow-net --allow-env --allow-read main.ts"
          },
          "imports": {
            "fresh": "https://deno.land/x/fresh/mod.ts"
          }
        }
        """

        let main = """
        const port = Number(Deno.env.get("PORT")) || 8080;

        Deno.serve({ port, hostname: "0.0.0.0" }, (req: Request) => {
          const url = new URL(req.url);
          if (url.pathname === "/health") {
            return new Response("ok");
          }
          return new Response("Hello from \(serviceName)!");
        });
        """

        try writeFile(at: directory.appendingPathComponent("deno.json"), content: denoJSON)
        try writeFile(at: directory.appendingPathComponent("main.ts"), content: main)
        try writeFile(at: directory.appendingPathComponent(".gitignore"), content: denoGitignore)
    }
}

struct DenoPlainTemplate: ProjectTemplate {
    let runtime: RuntimeKind = .deno
    let framework: FrameworkKind = .plain
    let displayName = "Plain (no framework)"

    func scaffold(at directory: URL, serviceName: String) throws {
        try ensureDirectory(at: directory)

        let denoJSON = """
        {
          "name": "\(serviceName)",
          "tasks": {
            "dev": "deno run --watch --allow-net --allow-env main.ts",
            "start": "deno run --allow-net --allow-env main.ts"
          }
        }
        """

        let main = """
        const port = Number(Deno.env.get("PORT")) || 8080;
        console.log(`Starting \(serviceName) on port ${port}`);

        Deno.serve({ port, hostname: "0.0.0.0" }, (req: Request) => {
          const url = new URL(req.url);
          if (url.pathname === "/health") {
            return new Response("ok");
          }
          return new Response("Hello from \(serviceName)!");
        });
        """

        try writeFile(at: directory.appendingPathComponent("deno.json"), content: denoJSON)
        try writeFile(at: directory.appendingPathComponent("main.ts"), content: main)
        try writeFile(at: directory.appendingPathComponent(".gitignore"), content: denoGitignore)
    }
}

private let denoGitignore = """
.DS_Store
"""
