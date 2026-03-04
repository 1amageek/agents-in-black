import AIBConfig
import AIBRuntimeCore
import Darwin
import Foundation

public final class DefaultProcessController: ProcessController {
    public init() {}

    public func spawn(
        service: ServiceConfig,
        resolvedPort: Int,
        gatewayPort: Int,
        configBaseDirectory: String
    ) async throws -> ChildHandle {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let cwd = service.cwd.map { path in
            URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: configBaseDirectory)).standardizedFileURL.path
        } ?? configBaseDirectory
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)

        guard let command = service.run.first else {
            throw ProcessSpawnError("Missing run command", metadata: ["service_id": service.id.rawValue])
        }
        let arguments = Array(service.run.dropFirst())

        // Launch through `/usr/bin/env` to preserve PATH lookup without invoking a shell.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + arguments

        // Build a clean, isolated environment instead of inheriting the host's
        // full environment. Only essential system variables are carried over.
        let hostEnv = ProcessInfo.processInfo.environment
        var env = buildBaseEnvironment(from: hostEnv)
        env["PATH"] = enrichedPATH(from: hostEnv["PATH"])
        guard commandIsResolvable(command, pathEnv: env["PATH"] ?? "", cwd: cwd) else {
            throw ProcessSpawnError("Command not found in PATH", metadata: [
                "service_id": service.id.rawValue,
                "command": command,
                "path": env["PATH"] ?? "",
            ])
        }

        // AIB runtime variables
        env["PORT"] = "\(resolvedPort)"
        env["AIB_SERVICE_ID"] = service.id.rawValue
        env["AIB_MOUNT_PATH"] = service.mountPath
        env["AIB_REQUEST_BASE_URL"] = "http://localhost:\(gatewayPort)\(service.mountPath)"
        env["AIB_DEV"] = "1"
        let sanitizedID = service.id.rawValue.replacingOccurrences(of: "/", with: "__")
        let connectionsFilePath = URL(fileURLWithPath: configBaseDirectory)
            .appendingPathComponent("generated/runtime/connections/\(sanitizedID).json")
            .standardizedFileURL.path
        if FileManager.default.fileExists(atPath: connectionsFilePath) {
            env["AIB_CONNECTIONS_FILE"] = connectionsFilePath
        }

        // For agent services, inject native MCP config into the isolated config directory.
        if service.kind == .agent {
            installMCPProjectConfig(sanitizedID: sanitizedID, configBaseDirectory: configBaseDirectory, env: &env)
        }

        // Force line-buffered stdout for Python processes (piped stdout
        // defaults to 8 KB block buffering, delaying all output).
        env["PYTHONUNBUFFERED"] = "1"

        // Service-specific env vars from workspace.yaml (highest priority).
        for (key, value) in service.env {
            env[key] = value
        }
        process.environment = env

        do {
            try process.run()
        } catch {
            throw ProcessSpawnError("Failed to spawn service", metadata: [
                "service_id": service.id.rawValue,
                "command": service.run.joined(separator: " "),
                "error": "\(error)",
            ])
        }

        var dedicatedGroup = false
        let pid = process.processIdentifier
        if pid > 0 {
            if Darwin.setpgid(pid, pid) == 0 {
                dedicatedGroup = true
            }
        }

        return ChildHandle(
            serviceID: service.id,
            process: process,
            stdoutPipe: stdoutPipe,
            stderrPipe: stderrPipe,
            startedAt: Date(),
            resolvedPort: resolvedPort,
            usesDedicatedProcessGroup: dedicatedGroup
        )
    }

    private func enrichedPATH(from current: String?) -> String {
        var components = (current ?? "")
            .split(separator: ":")
            .map(String.init)
            .filter { !$0.isEmpty }

        // Include user-local package manager paths
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let preferred = [
            "\(home)/Library/pnpm",
            "\(home)/.local/bin",
            "\(home)/.deno/bin",
            "\(home)/.cargo/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/Library/Frameworks/Python.framework/Versions/Current/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
        for path in preferred where !components.contains(path) {
            components.append(path)
        }
        return components.joined(separator: ":")
    }

    /// Build a minimal base environment for child processes.
    /// Only essential system variables are carried over from the host — everything
    /// else (tool-specific configs, MCP servers, etc.) is excluded by default.
    private func buildBaseEnvironment(from hostEnv: [String: String]) -> [String: String] {
        // Keys required for basic process operation, locale, and toolchain resolution.
        let allowedKeys: Set<String> = [
            "HOME", "USER", "LOGNAME", "SHELL",
            "LANG", "LC_ALL", "LC_CTYPE",
            "TMPDIR", "TERM",
            "SSH_AUTH_SOCK",
            // Toolchain environment (e.g., nvm, pyenv, rbenv)
            "NVM_DIR", "PYENV_ROOT", "RBENV_ROOT",
            "GOPATH", "GOROOT", "CARGO_HOME", "RUSTUP_HOME",
            "DENO_DIR",
            "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME",
        ]
        var base: [String: String] = [:]
        for key in allowedKeys {
            if let value = hostEnv[key] {
                base[key] = value
            }
        }
        return base
    }

    /// Set up an isolated Claude config directory containing only the AIB topology
    /// MCP servers. No files are written outside `.aib/`.
    private func installMCPProjectConfig(
        sanitizedID: String,
        configBaseDirectory: String,
        env: inout [String: String]
    ) {
        // Redirect CLAUDE_CONFIG_DIR to an isolated location inside .aib/
        // so the agent does not inherit MCP servers from the host's
        // ~/.claude.json or ~/.claude/settings.json.
        let isolatedConfigDir = URL(fileURLWithPath: configBaseDirectory)
            .appendingPathComponent("generated/runtime/claude-config/\(sanitizedID)")
            .standardizedFileURL
        try? FileManager.default.createDirectory(at: isolatedConfigDir, withIntermediateDirectories: true)

        // Read the generated .mcp.json and write its mcpServers into the isolated
        // .claude.json as user-scoped servers. This avoids writing any files to the
        // agent's source directory.
        let mcpSourcePath = URL(fileURLWithPath: configBaseDirectory)
            .appendingPathComponent("generated/runtime/mcp/\(sanitizedID)/.mcp.json")
            .standardizedFileURL

        var claudeConfig: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: mcpSourcePath.path),
           let data = try? Data(contentsOf: mcpSourcePath),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let servers = parsed["mcpServers"] {
            claudeConfig["mcpServers"] = servers
        }

        let configFilePath = isolatedConfigDir.appendingPathComponent(".claude.json")
        if let jsonData = try? JSONSerialization.data(withJSONObject: claudeConfig, options: [.prettyPrinted, .sortedKeys]) {
            try? jsonData.write(to: configFilePath, options: .atomic)
        }

        env["CLAUDE_CONFIG_DIR"] = isolatedConfigDir.path
        env["ENABLE_CLAUDEAI_MCP_SERVERS"] = "false"
    }

    private func commandIsResolvable(_ command: String, pathEnv: String, cwd: String) -> Bool {
        if command.contains("/") {
            let resolved = URL(fileURLWithPath: command, relativeTo: URL(fileURLWithPath: cwd)).standardizedFileURL.path
            return FileManager.default.isExecutableFile(atPath: resolved)
        }

        for directory in pathEnv.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(command).path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return true
            }
        }
        return false
    }

    public func terminateGroup(_ handle: ChildHandle, grace: Duration) async -> TerminationResult {
        let pid = handle.process.processIdentifier
        if pid > 0 {
            if handle.usesDedicatedProcessGroup {
                _ = Darwin.kill(-pid, SIGTERM)
            } else {
                handle.process.terminate()
            }
        }
        let deadline = Date().addingTimeInterval(grace.timeInterval)
        while handle.process.isRunning, Date() < deadline {
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                break
            }
        }
        return TerminationResult(terminatedGracefully: !handle.process.isRunning, exitCode: handle.process.isRunning ? nil : handle.process.terminationStatus)
    }

    public func killGroup(_ handle: ChildHandle) async {
        let pid = handle.process.processIdentifier
        if pid > 0 {
            if handle.usesDedicatedProcessGroup {
                _ = Darwin.kill(-pid, SIGKILL)
            } else {
                _ = Darwin.kill(pid, SIGKILL)
            }
        }
        while handle.process.isRunning {
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                break
            }
        }
    }
}
