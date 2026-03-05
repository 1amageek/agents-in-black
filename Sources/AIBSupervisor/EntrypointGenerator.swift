import AIBConfig
import Foundation

/// Generates per-service entrypoint scripts and runtime-native TCP-UDS bridge scripts.
///
/// Instead of building fragile inline shell commands, this generator writes proper
/// shell scripts and bridge programs to a host-side directory, which is then mounted
/// into the container via VirtioFS at `/aib-scripts/`.
///
/// The entrypoint script orchestrates these phases:
/// 1. Package manager setup (corepack enable pnpm, etc.)
/// 2. Platform-specific dependency isolation (node_modules bind mount)
/// 3. Dependency installation (pnpm install, pip install, etc.)
/// 4. Build step (optional)
/// 5. TCP-UDS bridge startup (runtime-native, background)
/// 6. Service startup (exec)
///
/// The TCP-UDS bridge is written in the runtime's own language (Node.js `net` module,
/// Python `socket` module, etc.) so it requires zero external dependencies.
/// This bridge is necessary because vmnet IPs are NAT'd and not routable from the host.
/// The host reaches services via UnixSocketRelay (vsock) which terminates at a guest UDS.
enum EntrypointGenerator {

    /// Output of script generation — host directory path containing generated scripts.
    struct GeneratedScripts {
        /// Host directory containing `entrypoint.sh` and bridge script.
        let directory: URL
        /// Bridge startup command (e.g., `node /aib-scripts/bridge.js`).
        let bridgeCommand: String
    }

    /// Generate entrypoint and bridge scripts for a service.
    ///
    /// - Parameters:
    ///   - service: Service configuration.
    ///   - runtime: Detected runtime (node, python, deno, swift, unknown).
    ///   - baseDir: Parent directory for script directories.
    ///   - containerID: Unique container identifier (used for directory naming).
    /// - Returns: Generated script paths and bridge command.
    static func generate(
        service: ServiceConfig,
        runtime: Runtime,
        baseDir: URL,
        containerID: String
    ) throws -> GeneratedScripts {
        let scriptDir = baseDir.appendingPathComponent("scripts/\(containerID)")
        try FileManager.default.createDirectory(at: scriptDir, withIntermediateDirectories: true)

        let bridgeCmd = try writeBridgeScript(runtime: runtime, to: scriptDir)
        try writeEntrypoint(to: scriptDir)

        return GeneratedScripts(directory: scriptDir, bridgeCommand: bridgeCmd)
    }

    /// Clean up generated scripts for a container.
    static func cleanup(directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Runtime Detection

    /// Supported container runtimes.
    enum Runtime: String {
        case node
        case bun
        case python
        case deno
        case swift
        case unknown
    }

    /// Detect the runtime from the service's run command and package manager.
    static func detectRuntime(service: ServiceConfig) -> Runtime {
        // Check package manager first — bun as package manager implies bun runtime
        if let pm = detectPackageManager(service: service), pm == "bun" {
            return .bun
        }
        guard let command = service.run.first else { return .unknown }
        switch command {
        case "bun":
            return .bun
        case "node", "npx", "npm", "yarn", "pnpm", "tsx", "ts-node":
            return .node
        case "python", "python3", "pip", "uvicorn", "gunicorn", "uv":
            return .python
        case "deno":
            return .deno
        case "swift":
            return .swift
        default:
            return .unknown
        }
    }

    /// Detect the package manager from install/run commands.
    static func detectPackageManager(service: ServiceConfig) -> String? {
        let commands = (service.install ?? []) + service.run
        let joined = commands.joined(separator: " ")
        if joined.contains("pnpm") { return "pnpm" }
        if joined.contains("yarn") { return "yarn" }
        if joined.contains("bun") { return "bun" }
        if joined.contains("uv") { return "uv" }
        if joined.contains("poetry") { return "poetry" }
        return nil
    }

    /// Directory name containing platform-specific dependencies that must be
    /// isolated between the macOS host and Linux guest.
    /// Returns `nil` for runtimes with no platform-specific module directory.
    static func platformModulesDir(runtime: Runtime) -> String? {
        switch runtime {
        case .node, .bun:
            return "node_modules"
        case .python, .deno, .swift, .unknown:
            return nil
        }
    }

    // MARK: - Entrypoint Script

    private static func writeEntrypoint(to dir: URL) throws {
        let script = """
        #!/bin/sh
        set -e

        # Phase 1: Package Manager Setup
        if [ -n "$AIB_PACKAGE_MANAGER" ]; then
            echo "[aib] Setting up package manager: $AIB_PACKAGE_MANAGER"
            case "$AIB_PACKAGE_MANAGER" in
                pnpm) command -v pnpm >/dev/null 2>&1 || corepack enable pnpm 2>/dev/null || npm install -g pnpm ;;
                yarn) command -v yarn >/dev/null 2>&1 || corepack enable yarn 2>/dev/null || npm install -g yarn ;;
                bun)  command -v bun  >/dev/null 2>&1 || npm install -g bun ;;
                uv)   command -v uv   >/dev/null 2>&1 || pip install uv ;;
            esac
        fi

        # Phase 1.5: Isolate platform-specific dependencies
        # Source directory is VirtioFS-mounted from the macOS host.
        # node_modules may contain darwin-arm64 native binaries (e.g. esbuild)
        # which won't work on Linux. Even if node_modules doesn't exist yet,
        # we must isolate it so that `install` creates linux-arm64 binaries
        # in the guest without contaminating the host filesystem.
        if [ -n "$AIB_MODULES_DIR" ]; then
            echo "[aib] Isolating $AIB_MODULES_DIR (platform: darwin -> linux)"
            mkdir -p "/app/$AIB_MODULES_DIR"
            mkdir -p "/tmp/guest-modules"
            mount --bind /tmp/guest-modules "/app/$AIB_MODULES_DIR"
        fi

        # Phase 2: Install Dependencies
        if [ -n "$AIB_INSTALL_COMMAND" ]; then
            echo "[aib] Installing dependencies: $AIB_INSTALL_COMMAND"
            eval "$AIB_INSTALL_COMMAND"
        fi

        # Phase 3: Build
        if [ -n "$AIB_BUILD_COMMAND" ]; then
            echo "[aib] Building: $AIB_BUILD_COMMAND"
            eval "$AIB_BUILD_COMMAND"
        fi

        # Phase 3.5: Prepare writable Claude config directory
        # Runtime artifacts are mounted read-only at /aib-runtime.
        # Claude Agent SDK writes debug traces under CLAUDE_CONFIG_DIR/debug,
        # so the runtime config must be copied to a writable path.
        if [ -n "$CLAUDE_CONFIG_DIR" ]; then
            mkdir -p "$CLAUDE_CONFIG_DIR/debug"
            if [ -n "$AIB_CLAUDE_CONFIG_SOURCE" ] && [ -d "$AIB_CLAUDE_CONFIG_SOURCE" ]; then
                cp -R "$AIB_CLAUDE_CONFIG_SOURCE"/. "$CLAUDE_CONFIG_DIR"/ 2>/dev/null || true
            fi
        fi

        # Phase 4: Start TCP-UDS Bridge (background)
        # Required because vmnet IPs are NAT'd — host cannot connect directly.
        # UnixSocketRelay (vsock) exposes /tmp/aib-svc.sock to the host.
        # Bridge relays: TCP localhost:PORT <-> /tmp/aib-svc.sock
        if [ -n "$AIB_BRIDGE_COMMAND" ]; then
            echo "[aib] Starting TCP-UDS bridge"
            eval "$AIB_BRIDGE_COMMAND" &
            sleep 0.3
        fi

        # Phase 5: Start Service
        echo "[aib] Starting service: $AIB_RUN_COMMAND"
        exec $AIB_RUN_COMMAND
        """
        let path = dir.appendingPathComponent("entrypoint.sh")
        try script.write(to: path, atomically: true, encoding: .utf8)
    }

    // MARK: - Bridge Scripts

    /// Write a runtime-native bridge script and return the command to invoke it.
    private static func writeBridgeScript(runtime: Runtime, to dir: URL) throws -> String {
        switch runtime {
        case .node:
            try writeNodeBridge(to: dir)
            return "node /aib-scripts/bridge.js"
        case .bun:
            // Bun is Node.js-compatible — same bridge script, different binary.
            try writeNodeBridge(to: dir)
            return "bun run /aib-scripts/bridge.js"
        case .python:
            try writePythonBridge(to: dir)
            return "python3 /aib-scripts/bridge.py"
        case .deno:
            try writeDenoBridge(to: dir)
            return "deno run --allow-net --allow-read --allow-env /aib-scripts/bridge.ts"
        case .swift, .unknown:
            return socatFallbackCommand()
        }
    }

    private static func writeNodeBridge(to dir: URL) throws {
        let script = """
        // TCP-UDS bridge: relay connections from Unix domain socket to TCP.
        // Used by AIB to expose container services to the host via vsock.
        const net = require('net');
        const fs = require('fs');
        const PORT = parseInt(process.env.PORT || '3000', 10);
        const UDS = '/tmp/aib-svc.sock';

        try { fs.unlinkSync(UDS); } catch (e) {}

        const server = net.createServer(udsConn => {
            const tcpConn = net.createConnection({ port: PORT, host: '127.0.0.1' }, () => {
                udsConn.pipe(tcpConn);
                tcpConn.pipe(udsConn);
            });
            tcpConn.on('error', () => udsConn.destroy());
            udsConn.on('error', () => tcpConn.destroy());
        });

        server.listen(UDS, () => {
            console.error('[aib-bridge] listening on ' + UDS + ' -> TCP localhost:' + PORT);
        });

        server.on('error', err => {
            console.error('[aib-bridge] server error:', err.message);
            process.exit(1);
        });
        """
        let path = dir.appendingPathComponent("bridge.js")
        try script.write(to: path, atomically: true, encoding: .utf8)
    }

    private static func writePythonBridge(to dir: URL) throws {
        let script = """
        #!/usr/bin/env python3
        \"\"\"TCP-UDS bridge: relay connections from Unix domain socket to TCP.\"\"\"
        import os, socket, sys, threading

        PORT = int(os.environ.get('PORT', '3000'))
        UDS = '/tmp/aib-svc.sock'

        try:
            os.unlink(UDS)
        except OSError:
            pass


        def relay(src, dst):
            try:
                while True:
                    data = src.recv(65536)
                    if not data:
                        break
                    dst.sendall(data)
            except Exception:
                pass
            finally:
                src.close()
                dst.close()


        def main():
            srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            srv.bind(UDS)
            srv.listen(128)
            print(f'[aib-bridge] listening on {UDS} -> TCP localhost:{PORT}', file=sys.stderr)

            while True:
                conn, _ = srv.accept()
                try:
                    tcp = socket.create_connection(('127.0.0.1', PORT))
                except Exception as e:
                    print(f'[aib-bridge] TCP connect failed: {e}', file=sys.stderr)
                    conn.close()
                    continue
                threading.Thread(target=relay, args=(conn, tcp), daemon=True).start()
                threading.Thread(target=relay, args=(tcp, conn), daemon=True).start()


        if __name__ == '__main__':
            main()
        """
        let path = dir.appendingPathComponent("bridge.py")
        try script.write(to: path, atomically: true, encoding: .utf8)
    }

    private static func writeDenoBridge(to dir: URL) throws {
        let script = """
        // TCP-UDS bridge for Deno runtime.
        const PORT = parseInt(Deno.env.get('PORT') || '3000', 10);
        const UDS = '/tmp/aib-svc.sock';

        try { Deno.removeSync(UDS); } catch {}

        async function relay(src: Deno.Conn, dst: Deno.Conn) {
            const buf = new Uint8Array(65536);
            try {
                while (true) {
                    const n = await src.read(buf);
                    if (n === null) break;
                    await dst.write(buf.subarray(0, n));
                }
            } catch {}
            try { src.close(); } catch {}
            try { dst.close(); } catch {}
        }

        const listener = Deno.listen({ path: UDS, transport: 'unix' });
        console.error(`[aib-bridge] listening on ${UDS} -> TCP localhost:${PORT}`);

        for await (const udsConn of listener) {
            try {
                const tcpConn = await Deno.connect({ port: PORT, hostname: '127.0.0.1' });
                relay(udsConn, tcpConn);
                relay(tcpConn, udsConn);
            } catch (e) {
                console.error('[aib-bridge] TCP connect failed:', e);
                try { udsConn.close(); } catch {}
            }
        }
        """
        let path = dir.appendingPathComponent("bridge.ts")
        try script.write(to: path, atomically: true, encoding: .utf8)
    }

    /// Fallback for runtimes without a native bridge: use socat (best-effort).
    private static func socatFallbackCommand() -> String {
        "(command -v socat >/dev/null 2>&1 || (apt-get update -qq && apt-get install -y -qq socat >/dev/null 2>&1)) && rm -f /tmp/aib-svc.sock && socat UNIX-LISTEN:/tmp/aib-svc.sock,fork,reuseaddr TCP:127.0.0.1:$PORT"
    }
}
