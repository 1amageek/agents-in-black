import AIBConfig
import Foundation

/// Generates per-service entrypoint scripts.
///
/// The script directory is mounted into the guest via VirtioFS at `/aib-scripts/`.
enum EntrypointGenerator {
    /// Sentinel line emitted when the entrypoint transitions to the service run phase.
    static let runPhaseStartedMarker = "__AIB_RUN_PHASE_STARTED__"

    /// Output of script generation — host directory path containing generated scripts.
    struct GeneratedScripts {
        /// Host directory containing `entrypoint.sh`.
        let directory: URL
    }

    /// Generate entrypoint script for a service.
    static func generate(
        service: ServiceConfig,
        runtime: Runtime,
        baseDir: URL,
        containerID: String
    ) throws -> GeneratedScripts {
        let scriptDir = baseDir.appendingPathComponent("scripts/\(containerID)")
        try FileManager.default.createDirectory(at: scriptDir, withIntermediateDirectories: true)

        try writeEntrypoint(to: scriptDir)
        return GeneratedScripts(directory: scriptDir)
    }

    /// Clean up generated scripts for a container.
    static func cleanup(directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Runtime Detection

    enum Runtime: String {
        case node
        case bun
        case python
        case deno
        case swift
        case unknown
    }

    static func detectRuntime(service: ServiceConfig) -> Runtime {
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

        # Phase 4: Prepare writable Claude config directory
        if [ -n "$CLAUDE_CONFIG_DIR" ]; then
            mkdir -p "$CLAUDE_CONFIG_DIR/debug"
            if [ -n "$AIB_CLAUDE_CONFIG_SOURCE" ] && [ -d "$AIB_CLAUDE_CONFIG_SOURCE" ]; then
                cp -R "$AIB_CLAUDE_CONFIG_SOURCE"/. "$CLAUDE_CONFIG_DIR"/ 2>/dev/null || true
            fi
        fi

        # Phase 5: Start Service
        echo "[aib] Starting service: $AIB_RUN_COMMAND"
        echo "\(runPhaseStartedMarker)"
        exec $AIB_RUN_COMMAND
        """
        let path = dir.appendingPathComponent("entrypoint.sh")
        try script.write(to: path, atomically: true, encoding: .utf8)
    }
}
