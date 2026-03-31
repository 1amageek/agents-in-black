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

        try writeEntrypoint(to: scriptDir, service: service, runtime: runtime)
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

    /// Shell-quote a single argument for safe embedding in a script.
    private static func shellQuote(_ arg: String) -> String {
        if arg.isEmpty { return "''" }
        // If the argument contains no special characters, return as-is
        let safe = arg.allSatisfy { c in
            c.isLetter || c.isNumber || c == "/" || c == "." || c == "-" || c == "_" || c == "=" || c == ":"
        }
        if safe { return arg }
        // Single-quote the argument, escaping any embedded single quotes
        return "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Convert a command array to a shell command string with proper quoting.
    private static func shellCommand(_ argv: [String]) -> String {
        argv.map { shellQuote($0) }.joined(separator: " ")
    }

    private static func writeEntrypoint(to dir: URL, service: ServiceConfig, runtime: Runtime) throws {
        let installCommand = service.install.map { shellCommand($0) }
        let buildCommand = service.build.map { shellCommand($0) }
        let runCommand = shellCommand(service.run)

        var lines: [String] = []
        lines.append("#!/bin/sh")
        lines.append("set -e")
        lines.append("")
        lines.append("AIB_SCRIPT_STARTED_AT=$(date +%s%3N)")
        lines.append("aib_log() {")
        lines.append("    now=$(date +%s%3N)")
        lines.append("    elapsed_ms=$((now - AIB_SCRIPT_STARTED_AT))")
        lines.append(#"    printf '%s [elapsed_ms=%s] %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")" "$elapsed_ms" "$*""#)
        lines.append("}")
        lines.append("")
        lines.append("ensure_apt_packages() {")
        lines.append("    if ! command -v apt-get >/dev/null 2>&1; then")
        lines.append(#"        aib_log "[aib] apt-get unavailable — cannot install required system packages: $*""#)
        lines.append("        return 1")
        lines.append("    fi")
        lines.append("    apt_started_at=$(date +%s%3N)")
        lines.append("    export DEBIAN_FRONTEND=noninteractive")
        lines.append("    apt-get update -qq >/dev/null 2>&1")
        lines.append("    apt-get install -y -qq \"$@\" >/dev/null 2>&1")
        lines.append("    rm -rf /var/lib/apt/lists/*")
        lines.append("    aib_log \"[aib] apt-get completed for: $* (duration_ms=$(( $(date +%s%3N) - apt_started_at )))\"")
        lines.append("}")
        lines.append("")

        // Phase 1: Package Manager Setup
        lines.append("# Phase 1: Package Manager Setup")
        lines.append(#"if [ -n "$AIB_PACKAGE_MANAGER" ]; then"#)
        lines.append("    phase_started_at=$(date +%s%3N)")
        lines.append(#"    aib_log "[aib] Setting up package manager: $AIB_PACKAGE_MANAGER""#)
        lines.append(#"    case "$AIB_PACKAGE_MANAGER" in"#)
        lines.append(#"        pnpm) command -v pnpm >/dev/null 2>&1 || corepack enable pnpm 2>/dev/null || npm install -g pnpm ;;"#)
        lines.append(#"        yarn) command -v yarn >/dev/null 2>&1 || corepack enable yarn 2>/dev/null || npm install -g yarn ;;"#)
        lines.append(#"        bun)  command -v bun  >/dev/null 2>&1 || npm install -g bun ;;"#)
        lines.append(#"        uv)   command -v uv   >/dev/null 2>&1 || pip install uv ;;"#)
        lines.append("    esac")
        lines.append(#"    aib_log "[aib] Package manager ready: $AIB_PACKAGE_MANAGER (duration_ms=$(( $(date +%s%3N) - phase_started_at )))""#)
        lines.append("fi")
        lines.append("")

        // Phase 1.1: Extract pre-cached system tools
        lines.append("# Phase 1.1: Extract pre-cached system tools")
        lines.append("if [ -f /aib-tools/tools.tar.gz ]; then")
        lines.append("    phase_started_at=$(date +%s%3N)")
        lines.append(#"    aib_log "[aib] Extracting cached tools""#)
        lines.append("    tar xzf /aib-tools/tools.tar.gz -C / 2>/dev/null || true")
        lines.append(#"    aib_log "[aib] Cached tools extracted (duration_ms=$(( $(date +%s%3N) - phase_started_at )))""#)
        lines.append("fi")
        lines.append("")
        lines.append("# Phase 1.2: Self-heal required system tools")
        lines.append("if ! (command -v git >/dev/null 2>&1 && git --version >/dev/null 2>&1); then")
        lines.append(#"    aib_log "[aib] Repairing git toolchain""#)
        lines.append("    ensure_apt_packages git")
        lines.append("fi")
        // Phase 1.5: Isolate platform-specific dependencies
        lines.append("# Phase 1.5: Isolate platform-specific dependencies")
        lines.append(#"if [ "$AIB_PREPARED_WORKSPACE" != "1" ] && [ -n "$AIB_MODULES_DIR" ]; then"#)
        lines.append(#"    aib_log "[aib] Isolating $AIB_MODULES_DIR (platform: darwin -> linux)""#)
        lines.append(#"    mkdir -p "/app/$AIB_MODULES_DIR""#)
        lines.append(#"    mkdir -p "/tmp/guest-modules""#)
        lines.append(#"    mount --bind /tmp/guest-modules "/app/$AIB_MODULES_DIR""#)
        lines.append("fi")
        lines.append("")

        // Phase 2: Install Dependencies (command embedded directly, no eval)
        if let cmd = installCommand {
            lines.append("# Phase 2: Install Dependencies")
            lines.append(#"if [ "$AIB_PREPARED_WORKSPACE" = "1" ]; then"#)
            lines.append(#"    aib_log "[aib] Prepared workspace detected — skipping install phase""#)
            lines.append("else")
            lines.append("    phase_started_at=$(date +%s%3N)")
            lines.append("    aib_log \"[aib] Installing dependencies: \(cmd)\"")
            lines.append("    \(cmd)")
            lines.append("    aib_log \"[aib] Install phase completed (duration_ms=$(( $(date +%s%3N) - phase_started_at )))\"")
            lines.append("fi")
            lines.append("")
        }

        // Phase 3: Build
        if let cmd = buildCommand {
            lines.append("# Phase 3: Build")
            lines.append(#"if [ "$AIB_PREPARED_WORKSPACE" = "1" ]; then"#)
            lines.append(#"    aib_log "[aib] Prepared workspace detected — skipping build phase""#)
            lines.append("else")
            lines.append("    phase_started_at=$(date +%s%3N)")
            lines.append("    aib_log \"[aib] Building: \(cmd)\"")
            lines.append("    \(cmd)")
            lines.append("    aib_log \"[aib] Build phase completed (duration_ms=$(( $(date +%s%3N) - phase_started_at )))\"")
            lines.append("fi")
            lines.append("")
        }

        // Phase 4: Prepare writable Claude config directory
        lines.append("# Phase 4: Prepare writable Claude config directory")
        lines.append(#"if [ -n "$CLAUDE_CONFIG_DIR" ]; then"#)
        lines.append(#"    mkdir -p "$CLAUDE_CONFIG_DIR/debug""#)
        lines.append(#"    if [ -n "$AIB_CLAUDE_CONFIG_SOURCE" ] && [ -d "$AIB_CLAUDE_CONFIG_SOURCE" ]; then"#)
        lines.append(#"        cp -R "$AIB_CLAUDE_CONFIG_SOURCE"/. "$CLAUDE_CONFIG_DIR"/ 2>/dev/null || true"#)
        lines.append("    fi")
        lines.append("fi")
        lines.append("")

        let relayCommand: String?
        switch runtime {
        case .node:
            relayCommand = #"node -e 'const fs=require("fs"); const net=require("net"); const [socketPath, port]=process.argv.slice(1); try { fs.rmSync(socketPath, { force: true }); } catch {} const server=net.createServer((client)=>{ const upstream=net.connect({ host: "127.0.0.1", port: Number(port) }); client.pipe(upstream); upstream.pipe(client); const closePair=()=>{ client.destroy(); upstream.destroy(); }; client.on("error", closePair); upstream.on("error", closePair); }); server.listen(socketPath);' "$AIB_GUEST_SOCKET_PATH" "$PORT" &"#
        default:
            relayCommand = nil
        }

        if let relayCommand {
            lines.append("# Phase 4.5: Start UDS-to-TCP relay for host port forwarding")
            lines.append(#"if [ -n "$AIB_GUEST_SOCKET_PATH" ]; then"#)
            lines.append(#"    aib_log "[aib] Starting UDS relay: $AIB_GUEST_SOCKET_PATH -> localhost:$PORT""#)
            lines.append("    \(relayCommand)")
            lines.append("fi")
            lines.append("")
        }

        // Phase 5: Start Service
        lines.append("# Phase 5: Start Service")
        lines.append("aib_log \"[aib] Starting service: \(runCommand)\"")
        lines.append("echo \"\(runPhaseStartedMarker)\"")
        lines.append("exec \(runCommand)")

        let script = lines.joined(separator: "\n") + "\n"
        let path = dir.appendingPathComponent("entrypoint.sh")
        try script.write(to: path, atomically: true, encoding: .utf8)
    }
}
