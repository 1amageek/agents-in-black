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

        var env = ProcessInfo.processInfo.environment
        env["PORT"] = "\(resolvedPort)"
        env["AIB_SERVICE_ID"] = service.id.rawValue
        env["AIB_MOUNT_PATH"] = service.mountPath
        env["AIB_REQUEST_BASE_URL"] = "http://localhost:\(gatewayPort)\(service.mountPath)"
        env["AIB_DEV"] = "1"
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
            try? await Task.sleep(for: .milliseconds(100))
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
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}
