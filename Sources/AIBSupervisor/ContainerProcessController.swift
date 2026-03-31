import AIBConfig
import AIBRuntimeCore
import CryptoKit
import Containerization
import ContainerizationExtras
import Darwin
import Foundation
import Logging
import Synchronization

/// Process controller that runs each service in a Linux VM using apple/containerization.
///
/// Uses the Containerization framework directly — no daemon or XPC service required.
/// Each container is a lightweight Linux VM via Virtualization.framework.
///
/// Requirements:
/// - macOS 26+ on Apple Silicon
/// - `com.apple.security.virtualization` entitlement
/// - Linux kernel binary (vmlinux) — auto-discovered or downloaded
public actor ContainerProcessController: ProcessController {
    private final class HostManagedProcess: @unchecked Sendable {
        let process: Process
        let stdoutHandle: FileHandle
        let stderrHandle: FileHandle

        init(process: Process, stdoutHandle: FileHandle, stderrHandle: FileHandle) {
            self.process = process
            self.stdoutHandle = stdoutHandle
            self.stderrHandle = stderrHandle
        }
    }

    private let logger: Logger

    /// Observable progress for one-time setup tasks (kernel download).
    /// Thread-safe (`Progress` is `Sendable`) so the App can observe from `@MainActor`
    /// while the actor updates it during download.
    public nonisolated let setupProgress: Progress

    /// Shared container manager (lazy-initialized on first spawn).
    private var manager: ContainerManager?

    /// Active containers keyed by container ID for lifecycle management.
    private var containers: [String: LinuxContainer] = [:]
    /// Active host-managed processes keyed by process ID for convenience-mode runtime.
    private var hostProcesses: [String: HostManagedProcess] = [:]

    /// Directory for generated entrypoint scripts.
    private let scriptRootDir: URL

    /// Legacy directory for host-side Unix domain sockets.
    /// Retained only for cleanup compatibility with older runs.
    private let socketDir: URL

    /// Cache directory for kernel, init image, and OCI image store.
    private let cacheRoot: URL

    /// Directory for cached base image tool archives (git, ssh, etc.).
    private let baseSetupDir: URL

    /// Versioned namespace for cached base tool archives.
    /// Bump when the archive layout or dependency closure logic changes.
    private static let baseSetupVersion = "v5"
    private static let preparedWorkspaceCacheVersion = "v2"

    /// Runtimes that have already been warmed (tool archive built and cached).
    private var warmedRuntimes: Set<String> = []
    /// In-flight base-image warming tasks keyed by runtime.
    private var warmingTasks: [String: Task<Void, Error>] = [:]

    public init(logger: Logger) {
        self.logger = logger
        self.setupProgress = Progress(totalUnitCount: 0)
        self.cacheRoot = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".aib/container-cache")
        self.scriptRootDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aib-runtime-scripts")
        self.socketDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aib-sockets")
        self.baseSetupDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".aib/container-cache/base-setup")
    }

    private func elapsedMilliseconds(since startedAt: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(startedAt) * 1000))
    }

    // MARK: - ProcessController

    public func spawn(
        service: ServiceConfig,
        resolvedPort: Int,
        gatewayPort: Int,
        configBaseDirectory: String
    ) async throws -> ChildHandle {
        let spawnStartedAt = Date()
        let cwd = service.cwd.map { path in
            URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: configBaseDirectory))
                .standardizedFileURL.path
        } ?? configBaseDirectory

        // Detect runtime for entrypoint generation
        let runtime = EntrypointGenerator.detectRuntime(service: service)
        let preparedWorkspace = service.env["AIB_PREPARED_WORKSPACE"] == "1"
        let buildMode = AIBBuildMode(rawValue: service.env["AIB_BUILD_MODE"] ?? "") ?? .strict
        var effectiveService = service
        if let preparedRunCommand = resolvedPreparedWorkspaceRunCommand(
            for: service,
            runtime: runtime,
            cwd: cwd,
            preparedWorkspace: preparedWorkspace
        ) {
            effectiveService.run = preparedRunCommand
            logger.info("Using stable run command for prepared workspace", metadata: [
                "service_id": .string(service.id.rawValue),
                "original": .string(service.run.joined(separator: " ")),
                "resolved": .string(preparedRunCommand.joined(separator: " ")),
            ])
        }
        let packageManager = EntrypointGenerator.detectPackageManager(service: effectiveService)

        if buildMode == .convenience, runtime == .node {
            return try spawnHostProcess(
                service: effectiveService,
                resolvedPort: resolvedPort,
                gatewayPort: gatewayPort,
                configBaseDirectory: configBaseDirectory,
                cwd: cwd,
                preparedWorkspace: preparedWorkspace,
                spawnStartedAt: spawnStartedAt
            )
        }

        // Ensure the container manager is initialized (kernel + initfs + image store)
        try await ensureManager()

        let sanitizedID = service.id.rawValue.replacingOccurrences(of: "/", with: "-")
        let containerID = "aib-\(sanitizedID)-\(UUID().uuidString.prefix(8).lowercased())"

        // Ensure base image has required system tools pre-installed and cached
        let baseImageWarmStartedAt = Date()
        try await ensureBaseImageWarmed(runtime: runtime)
        logger.info("Base image ready for service container", metadata: [
            "service_id": .string(service.id.rawValue),
            "runtime": .string(runtime.rawValue),
            "elapsed_ms": .stringConvertible(elapsedMilliseconds(since: baseImageWarmStartedAt)),
        ])

        // Determine OCI image reference
        let imageRef = try imageReference(for: service, runtime: runtime, packageManager: packageManager)

        // Generate entrypoint scripts (mounted via VirtioFS)
        let scripts = try EntrypointGenerator.generate(
            service: effectiveService,
            runtime: runtime,
            baseDir: scriptRootDir,
            containerID: containerID
        )

        let repoLocalPNPMStoreExists = !preparedWorkspace && FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: cwd).appendingPathComponent(".pnpm-store").path
        )
        let hostCorepackCachePath = buildMode == .convenience && !preparedWorkspace
            ? hostCorepackCachePath(for: runtime)
            : nil
        let hostPNPMStorePath = buildMode == .convenience && !preparedWorkspace && packageManager == "pnpm"
            ? hostPNPMStorePath()
            : nil

        let envArray = buildEnvironment(
            service: service,
            resolvedPort: resolvedPort,
            gatewayPort: gatewayPort,
            configBaseDirectory: configBaseDirectory,
            runtime: runtime,
            packageManager: packageManager,
            preparedWorkspace: preparedWorkspace,
            useRepoLocalPNPMStore: repoLocalPNPMStoreExists,
            useHostPNPMStore: !repoLocalPNPMStoreExists && hostPNPMStorePath != nil
        )

        try FileManager.default.createDirectory(at: scriptRootDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: socketDir, withIntermediateDirectories: true)

        let hostSocketPath = socketDir.appendingPathComponent("\(containerID).sock")
        try? FileManager.default.removeItem(at: hostSocketPath)

        let guestSocketPath = "/tmp/aib-svc.sock"

        // Resolve tool archive mount path before entering the Sendable closure
        let toolsDirPathForMount = toolsArchivePath(for: runtime)?.deletingLastPathComponent().path

        logger.info("Creating container", metadata: [
            "service_id": .string(service.id.rawValue),
            "container_id": .string(containerID),
            "image": .string(imageRef),
            "container_port": .stringConvertible(resolvedPort),
        ])

        // Create container via ContainerManager
        guard var mgr = self.manager else {
            throw ProcessSpawnError("Container manager not initialized", metadata: [:])
        }

        let runtimeDir = URL(fileURLWithPath: configBaseDirectory)
            .appendingPathComponent("generated/runtime")
            .standardizedFileURL.path
        let runtimeDirExists = FileManager.default.fileExists(atPath: runtimeDir)
        let runtimeSkillMounts = stagedRuntimeSkillMounts(
            serviceID: service.id.rawValue,
            configBaseDirectory: configBaseDirectory
        )

        // Shared runtime state and log writers to capture container stdout/stderr.
        let state = ContainerState()
        state.runPhaseStarted.withLock { $0 = false }
        let stdoutWriter = LogWriter(
            logger: logger,
            containerID: containerID,
            stream: "stdout",
            containerState: state
        )
        let stderrWriter = LogWriter(
            logger: logger,
            containerID: containerID,
            stream: "stderr"
        )

        logger.info("Container entrypoint", metadata: [
            "container_id": .string(containerID),
            "runtime": .string(runtime.rawValue),
            "scripts": .string(scripts.directory.path),
        ])

        let containerCreateStartedAt = Date()
        let container = try await mgr.create(
            containerID,
            reference: imageRef
        ) { config in
            // Process: run generated entrypoint script (mounted via VirtioFS)
            config.process.arguments = ["/bin/sh", "/aib-scripts/entrypoint.sh"]
            config.process.environmentVariables = envArray
            config.process.workingDirectory = "/app"
            config.process.stdout = stdoutWriter
            config.process.stderr = stderrWriter

            // Resources
            config.cpus = 2
            config.memoryInBytes = 512.mib()

            // Mount source directory via VirtioFS
            config.mounts.append(.share(source: cwd, destination: "/app"))

            // Mount generated scripts via VirtioFS
            config.mounts.append(.share(
                source: scripts.directory.path,
                destination: "/aib-scripts",
                options: ["ro"]
            ))

            // Mount runtime directory (read-only) for connection info and MCP config
            if runtimeDirExists {
                config.mounts.append(.share(
                    source: runtimeDir,
                    destination: "/aib-runtime",
                    options: ["ro"]
                ))
            }

            for mount in runtimeSkillMounts {
                config.mounts.append(.share(
                    source: mount.source,
                    destination: mount.destination,
                    options: ["ro"]
                ))
            }

            // Mount cached tool archive for extraction at startup
            if let toolsDirPath = toolsDirPathForMount {
                config.mounts.append(.share(
                    source: toolsDirPath,
                    destination: "/aib-tools",
                    options: ["ro"]
                ))
            }

            if let hostCorepackCachePath {
                config.mounts.append(.share(
                    source: hostCorepackCachePath,
                    destination: "/root/.cache/node/corepack",
                    options: ["ro"]
                ))
            }

            if let hostPNPMStorePath, !repoLocalPNPMStoreExists {
                config.mounts.append(.share(
                    source: hostPNPMStorePath,
                    destination: "/aib-pnpm-store",
                    options: ["ro"]
                ))
            }

            config.sockets = [
                UnixSocketConfiguration(
                    source: URL(filePath: guestSocketPath),
                    destination: hostSocketPath,
                    direction: .outOf
                ),
            ]
        }
        self.manager = mgr

        guard let containerAddress = container.interfaces.first?.ipv4Address.address.description else {
            throw ProcessSpawnError("Container network address unavailable", metadata: [
                "container_id": containerID,
            ])
        }
        logger.info("Container network configured", metadata: [
            "container_id": .string(containerID),
            "ip": .string(containerAddress),
            "elapsed_ms": .stringConvertible(elapsedMilliseconds(since: containerCreateStartedAt)),
        ])

        // Start the container VM
        let containerStartStartedAt = Date()
        try await container.create()
        do {
            try await container.start()
            logger.info("Container start completed", metadata: [
                "container_id": .string(containerID),
                "service_id": .string(service.id.rawValue),
                "elapsed_ms": .stringConvertible(elapsedMilliseconds(since: containerStartStartedAt)),
                "total_elapsed_ms": .stringConvertible(elapsedMilliseconds(since: spawnStartedAt)),
            ])
        } catch {
            do {
                try await container.stop()
            } catch {
                logger.debug("Container stop after start failure completed with error", metadata: [
                    "container_id": .string(containerID),
                    "error": .string("\(error)"),
                ])
            }
            cleanupManager(id: containerID)
            EntrypointGenerator.cleanup(directory: scripts.directory)
            throw error
        }

        // Track container for lifecycle management
        containers[containerID] = container

        // Monitor task: wait for container exit and record exit code
        let monitorTask = Task { [logger] in
            do {
                let exitStatus = try await container.wait()
                state.exitCode.withLock { $0 = exitStatus.exitCode }
                state.isAlive.withLock { $0 = false }
                logger.info("Container exited", metadata: [
                    "container_id": .string(containerID),
                    "exit_code": .string("\(exitStatus.exitCode)"),
                ])
            } catch {
                // CancellationError or VM shutdown — lifecycle managed elsewhere
                return
            }
        }

        return ChildHandle(
            serviceID: service.id,
            containerID: containerID,
            containerIPAddress: containerAddress,
            containerState: state,
            startedAt: Date(),
            resolvedPort: resolvedPort,
            backendEndpoint: BackendEndpoint(
                host: "127.0.0.1",
                port: resolvedPort,
                unixSocketPath: hostSocketPath.path
            ),
            usesRunPhaseSignal: true,
            scriptDir: scripts.directory,
            monitorTask: monitorTask,
            logTask: nil
        )
    }

    public func prepareNodeWorkspace(
        service: ServiceConfig,
        repoRoot: String,
        workspaceRoot: String,
        buildMode: AIBBuildMode,
        sourceCredentials: [AIBSourceCredential],
        sourceDependencies: [AIBSourceDependencyFinding],
        convenience: AIBConvenienceOptions?
    ) async throws -> String {
        let prepareStartedAt = Date()

        let runtime = EntrypointGenerator.detectRuntime(service: service)
        guard runtime == .node else {
            throw BuildPreparationError("Node workspace preparation is only supported for Node services", metadata: [
                "service_id": service.id.rawValue,
                "runtime": runtime.rawValue,
            ])
        }

        if buildMode == .convenience {
            return try prepareNodeWorkspaceForConvenienceMode(
                service: service,
                repoRoot: repoRoot,
                workspaceRoot: workspaceRoot,
                buildMode: buildMode,
                sourceCredentials: sourceCredentials,
                sourceDependencies: sourceDependencies,
                convenience: convenience,
                prepareStartedAt: prepareStartedAt
            )
        }

        try await ensureManager()

        let baseImageWarmStartedAt = Date()
        try await ensureBaseImageWarmed(runtime: runtime)
        logger.info("Base image ready for workspace preparation", metadata: [
            "service_id": .string(service.id.rawValue),
            "runtime": .string(runtime.rawValue),
            "elapsed_ms": .stringConvertible(elapsedMilliseconds(since: baseImageWarmStartedAt)),
            "total_elapsed_ms": .stringConvertible(elapsedMilliseconds(since: prepareStartedAt)),
        ])

        let sanitizedID = service.id.rawValue.replacingOccurrences(of: "/", with: "-")
        let buildRoot = URL(fileURLWithPath: workspaceRoot)
            .appendingPathComponent(".aib/state/local-build/\(sanitizedID)")
            .standardizedFileURL
        let stagedWorkspaceRoot = buildRoot.appendingPathComponent("workspace")
        let buildScriptRoot = buildRoot.appendingPathComponent("scripts")
        let authRoot = buildRoot.appendingPathComponent("auth")
        let sourceMirrorRoot = buildRoot.appendingPathComponent("source-mirrors")
        let preparedWorkspaceManifestURL = buildRoot.appendingPathComponent("prepared-workspace.json")
        let fileManager = FileManager.default
        let convenienceOptions = resolvedConvenienceOptions(for: buildMode, convenience: convenience)
        let fingerprintStartedAt = Date()
        let preparedWorkspaceFingerprint = try computePreparedWorkspaceFingerprint(
            service: service,
            repoRoot: repoRoot,
            buildMode: buildMode,
            sourceDependencies: sourceDependencies,
            sourceCredentials: sourceCredentials,
            convenience: convenienceOptions
        )
        logger.info("Prepared workspace fingerprint computed", metadata: [
            "service_id": .string(service.id.rawValue),
            "elapsed_ms": .stringConvertible(elapsedMilliseconds(since: fingerprintStartedAt)),
            "total_elapsed_ms": .stringConvertible(elapsedMilliseconds(since: prepareStartedAt)),
        ])

        if isPreparedWorkspaceCacheReusable(
            stagedWorkspaceRoot: stagedWorkspaceRoot,
            manifestURL: preparedWorkspaceManifestURL,
            expectedFingerprint: preparedWorkspaceFingerprint
        ) {
            logger.info("Reusing prepared Node workspace cache", metadata: [
                "service_id": .string(service.id.rawValue),
                "build_mode": .string(buildMode.rawValue),
                "staged_workspace": .string(stagedWorkspaceRoot.path),
                "total_elapsed_ms": .stringConvertible(elapsedMilliseconds(since: prepareStartedAt)),
            ])
            return stagedWorkspaceRoot.path
        }

        if fileManager.fileExists(atPath: buildRoot.path) {
            try fileManager.removeItem(at: buildRoot)
        }
        try fileManager.createDirectory(at: buildRoot, withIntermediateDirectories: true)

        let stageCopyStartedAt = Date()
        try stageWorkspaceCopy(from: repoRoot, to: stagedWorkspaceRoot)
        logger.info("Workspace staged for isolated builder", metadata: [
            "service_id": .string(service.id.rawValue),
            "staged_workspace": .string(stagedWorkspaceRoot.path),
            "elapsed_ms": .stringConvertible(elapsedMilliseconds(since: stageCopyStartedAt)),
            "total_elapsed_ms": .stringConvertible(elapsedMilliseconds(since: prepareStartedAt)),
        ])

        let repoLocalPNPMStorePath = URL(fileURLWithPath: repoRoot).appendingPathComponent(".pnpm-store").path
        let repoLocalPNPMStoreExists = convenienceOptions.useRepoLocalPNPMStore
            && fileManager.fileExists(atPath: repoLocalPNPMStorePath)
        let hostCorepackCachePath = convenienceOptions.useHostCorepackCache
            ? hostCorepackCachePath(for: runtime)
            : nil
        let hostPNPMStorePath = convenienceOptions.useHostPNPMStore
            ? hostPNPMStorePath()
            : nil
        let forwardedSSHAgentSocketHostPath = availableSSHAgentSocketPath()
        let forwardedSSHAgentSocketContainerPath = forwardedSSHAgentSocketHostPath.map { hostPath in
            let filename = URL(fileURLWithPath: hostPath).lastPathComponent
            return "/aib-ssh-agent/\(filename)"
        }

        var effectiveService = service
        if let inferredBuildCommand = inferredPreparedWorkspaceBuildCommand(
            for: service,
            runtime: runtime,
            cwd: stagedWorkspaceRoot.path
        ) {
            effectiveService.build = inferredBuildCommand
            logger.info("Using inferred build command for prepared workspace", metadata: [
                "service_id": .string(service.id.rawValue),
                "resolved": .string(inferredBuildCommand.joined(separator: " ")),
            ])
        }

        let sourceAuthStartedAt = Date()
        let authMountPath = try materializeLocalSourceAuth(
            authRoot: authRoot,
            dependencies: sourceDependencies,
            credentials: sourceCredentials
        )
        logger.info("Local source auth materialized", metadata: [
            "service_id": .string(service.id.rawValue),
            "path": .string(authRoot.path),
            "elapsed_ms": .stringConvertible(elapsedMilliseconds(since: sourceAuthStartedAt)),
            "total_elapsed_ms": .stringConvertible(elapsedMilliseconds(since: prepareStartedAt)),
        ])
        let sourceMirrorStartedAt = Date()
        let sourceMirrorMountPath = try materializeLocalSourceMirrors(
            mirrorsRoot: sourceMirrorRoot,
            authRoot: authRoot,
            dependencies: sourceDependencies,
            credentials: sourceCredentials
        )
        logger.info("Local source mirrors materialized", metadata: [
            "service_id": .string(service.id.rawValue),
            "path": .string(sourceMirrorRoot.path),
            "elapsed_ms": .stringConvertible(elapsedMilliseconds(since: sourceMirrorStartedAt)),
            "total_elapsed_ms": .stringConvertible(elapsedMilliseconds(since: prepareStartedAt)),
        ])
        let packageManager = EntrypointGenerator.detectPackageManager(service: effectiveService)
        let buildScriptStartedAt = Date()
        let scriptDir = try writeBuildPreparationScript(
            to: buildScriptRoot,
            service: effectiveService,
            packageManager: packageManager
        )
        logger.info("Build preparation script generated", metadata: [
            "service_id": .string(service.id.rawValue),
            "path": .string(scriptDir.path),
            "elapsed_ms": .stringConvertible(elapsedMilliseconds(since: buildScriptStartedAt)),
            "total_elapsed_ms": .stringConvertible(elapsedMilliseconds(since: prepareStartedAt)),
        ])
        let toolsDirPathForMount = toolsArchivePath(for: runtime)?.deletingLastPathComponent().path

        guard var mgr = self.manager else {
            throw BuildPreparationError("Container manager not initialized", metadata: [
                "service_id": service.id.rawValue,
            ])
        }

        let containerID = "aib-build-\(sanitizedID)-\(UUID().uuidString.prefix(8).lowercased())"
        let imageRef = baseImageReference(for: runtime)
        let stdoutWriter = LogWriter(
            logger: logger,
            containerID: containerID,
            stream: "stdout"
        )
        let stderrWriter = LogWriter(
            logger: logger,
            containerID: containerID,
            stream: "stderr"
        )
        let buildEnvironment = buildPreparationEnvironment(
            service: service,
            runtime: runtime,
            buildMode: buildMode,
            packageManager: packageManager,
            useRepoLocalPNPMStore: repoLocalPNPMStoreExists,
            useHostPNPMStore: !repoLocalPNPMStoreExists && hostPNPMStorePath != nil,
            forwardedSSHAgentSocketPath: forwardedSSHAgentSocketContainerPath
        )

        logger.info("Preparing Node workspace in isolated builder", metadata: [
            "service_id": .string(service.id.rawValue),
            "build_mode": .string(buildMode.rawValue),
            "repo_root": .string(repoRoot),
            "staged_workspace": .string(stagedWorkspaceRoot.path),
            "total_elapsed_ms": .stringConvertible(elapsedMilliseconds(since: prepareStartedAt)),
        ])

        let buildContainerCreateStartedAt = Date()
        let container = try await mgr.create(containerID, reference: imageRef) { config in
            config.process.arguments = ["/bin/sh", "/aib-build/build.sh"]
            config.process.environmentVariables = buildEnvironment
            config.process.workingDirectory = "/app"
            config.process.stdout = stdoutWriter
            config.process.stderr = stderrWriter
            config.cpus = 2
            config.memoryInBytes = 1024.mib()
            config.mounts.append(.share(source: stagedWorkspaceRoot.path, destination: "/app"))
            config.mounts.append(.share(
                source: scriptDir.path,
                destination: "/aib-build",
                options: ["ro"]
            ))

            if let toolsDirPath = toolsDirPathForMount {
                config.mounts.append(.share(
                    source: toolsDirPath,
                    destination: "/aib-tools",
                    options: ["ro"]
                ))
            }

            if let authMountPath {
                config.mounts.append(.share(
                    source: authMountPath,
                    destination: "/aib-auth",
                    options: ["ro"]
                ))
            }

            if let sourceMirrorMountPath {
                config.mounts.append(.share(
                    source: sourceMirrorMountPath,
                    destination: "/aib-source-mirrors",
                    options: ["ro"]
                ))
            }

            if let forwardedSSHAgentSocketHostPath {
                let socketDirectory = URL(fileURLWithPath: forwardedSSHAgentSocketHostPath)
                    .deletingLastPathComponent()
                    .path
                config.mounts.append(.share(
                    source: socketDirectory,
                    destination: "/aib-ssh-agent"
                ))
            }

            if let hostCorepackCachePath {
                config.mounts.append(.share(
                    source: hostCorepackCachePath,
                    destination: "/root/.cache/node/corepack",
                    options: ["ro"]
                ))
            }

            if repoLocalPNPMStoreExists {
                config.mounts.append(.share(
                    source: repoLocalPNPMStorePath,
                    destination: "/app/.pnpm-store"
                ))
            } else if let hostPNPMStorePath {
                config.mounts.append(.share(
                    source: hostPNPMStorePath,
                    destination: "/aib-pnpm-store",
                    options: ["ro"]
                ))
            }
        }
        self.manager = mgr
        logger.info("Build container created", metadata: [
            "service_id": .string(service.id.rawValue),
            "container_id": .string(containerID),
            "elapsed_ms": .stringConvertible(elapsedMilliseconds(since: buildContainerCreateStartedAt)),
            "total_elapsed_ms": .stringConvertible(elapsedMilliseconds(since: prepareStartedAt)),
        ])

        let buildContainerRunStartedAt = Date()
        try await container.create()
        do {
            try await container.start()
            let exitStatus = try await container.wait()
            if exitStatus.exitCode != 0 {
                throw BuildPreparationError("Node build preparation failed", metadata: [
                    "service_id": service.id.rawValue,
                    "exit_code": "\(exitStatus.exitCode)",
                    "build_mode": buildMode.rawValue,
                ])
            }
            logger.info("Build container completed", metadata: [
                "service_id": .string(service.id.rawValue),
                "container_id": .string(containerID),
                "elapsed_ms": .stringConvertible(elapsedMilliseconds(since: buildContainerRunStartedAt)),
                "total_elapsed_ms": .stringConvertible(elapsedMilliseconds(since: prepareStartedAt)),
            ])
        } catch let error as BuildPreparationError {
            do {
                try await container.stop()
            } catch {
                logger.debug("Build container stop after preparation error completed with error", metadata: [
                    "container_id": .string(containerID),
                    "error": .string("\(error)"),
                ])
            }
            cleanupBuildArtifacts(scriptDir: scriptDir, authRoot: authRoot)
            cleanupManager(id: containerID)
            throw error
        } catch {
            do {
                try await container.stop()
            } catch {
                logger.debug("Build container stop after unexpected preparation error completed with error", metadata: [
                    "container_id": .string(containerID),
                    "error": .string("\(error)"),
                ])
            }
            cleanupBuildArtifacts(scriptDir: scriptDir, authRoot: authRoot)
            cleanupManager(id: containerID)
            throw BuildPreparationError("Node build preparation failed", metadata: [
                "service_id": service.id.rawValue,
                "error": "\(error)",
                "build_mode": buildMode.rawValue,
            ])
        }

        do {
            try await container.stop()
        } catch {
            logger.debug("Build container stop completed with error", metadata: [
                "container_id": .string(containerID),
                "error": .string("\(error)"),
            ])
        }
        cleanupBuildArtifacts(scriptDir: scriptDir, authRoot: authRoot)
        cleanupManager(id: containerID)

        do {
            try writePreparedWorkspaceCacheManifest(
                at: preparedWorkspaceManifestURL,
                fingerprint: preparedWorkspaceFingerprint
            )
        } catch {
            logger.warning("Failed to persist prepared workspace cache manifest", metadata: [
                "service_id": .string(service.id.rawValue),
                "path": .string(preparedWorkspaceManifestURL.path),
                "error": .string("\(error)"),
            ])
        }

        logger.info("Prepared Node workspace ready", metadata: [
            "service_id": .string(service.id.rawValue),
            "staged_workspace": .string(stagedWorkspaceRoot.path),
            "total_elapsed_ms": .stringConvertible(elapsedMilliseconds(since: prepareStartedAt)),
        ])

        return stagedWorkspaceRoot.path
    }

    public func terminateGroup(_ handle: ChildHandle, grace: Duration) async -> TerminationResult {
        if let hostProcess = hostProcesses[handle.containerID] {
            if hostProcess.process.isRunning {
                _ = Darwin.kill(hostProcess.process.processIdentifier, SIGTERM)
            }

            let deadline = Date().addingTimeInterval(durationTimeInterval(grace))
            while hostProcess.process.isRunning && Date() < deadline {
                do {
                    try await Task.sleep(for: .milliseconds(100))
                } catch {
                    break
                }
            }

            if !hostProcess.process.isRunning {
                cleanupHostProcess(id: handle.containerID)
                handle.containerState.isAlive.withLock { $0 = false }
                return TerminationResult(
                    terminatedGracefully: true,
                    exitCode: handle.containerState.exitCode.withLock { $0 }
                )
            }

            return TerminationResult(
                terminatedGracefully: false,
                exitCode: handle.containerState.exitCode.withLock { $0 }
            )
        }

        guard let container = containers[handle.containerID] else {
            cleanupSocket(containerID: handle.containerID)
            return TerminationResult(terminatedGracefully: false, exitCode: nil)
        }
        // Stop host publish first to prevent new inbound connections while
        // the backend container is shutting down.
        cleanupSocket(containerID: handle.containerID)
        do {
            try await container.stop()
            handle.containerState.isAlive.withLock { $0 = false }
            handle.monitorTask?.cancel()
            containers.removeValue(forKey: handle.containerID)
            cleanupArtifacts(handle)
            cleanupManager(id: handle.containerID)
            logger.info("Container stopped gracefully", metadata: [
                "container_id": .string(handle.containerID),
                "service_id": .string(handle.serviceID.rawValue),
            ])
            return TerminationResult(terminatedGracefully: true, exitCode: 0)
        } catch {
            logger.warning("Container graceful stop failed", metadata: [
                "container_id": .string(handle.containerID),
                "error": .string("\(error)"),
            ])
            handle.monitorTask?.cancel()
            containers.removeValue(forKey: handle.containerID)
            cleanupArtifacts(handle)
            cleanupManager(id: handle.containerID)
            return TerminationResult(terminatedGracefully: false, exitCode: nil)
        }
    }

    public func killGroup(_ handle: ChildHandle) async {
        if let hostProcess = hostProcesses[handle.containerID] {
            if hostProcess.process.isRunning {
                _ = Darwin.kill(hostProcess.process.processIdentifier, SIGKILL)
            }
            handle.containerState.isAlive.withLock { $0 = false }
            cleanupHostProcess(id: handle.containerID)
            logger.info("Host process killed and cleaned up", metadata: [
                "container_id": .string(handle.containerID),
                "service_id": .string(handle.serviceID.rawValue),
            ])
            return
        }

        // Stop host publish first to prevent new inbound connections while
        // the backend container is terminating.
        cleanupSocket(containerID: handle.containerID)
        if let container = containers[handle.containerID] {
            do {
                try await container.kill(SIGKILL)
            } catch {
                // Best-effort — VM may already be dead
            }
            // container.stop() releases the VM's internal EventLoopGroup and gRPC connections.
            // Without this call, NIO threads leak and crash on stale fds during next start.
            do {
                try await container.stop()
            } catch {
                logger.debug("Container stop after kill completed with error (expected if VM already exited)", metadata: [
                    "container_id": .string(handle.containerID),
                    "error": .string("\(error)"),
                ])
            }
        }
        handle.containerState.isAlive.withLock { $0 = false }
        handle.monitorTask?.cancel()
        containers.removeValue(forKey: handle.containerID)
        cleanupArtifacts(handle)
        cleanupManager(id: handle.containerID)
        logger.info("Container killed and cleaned up", metadata: [
            "container_id": .string(handle.containerID),
            "service_id": .string(handle.serviceID.rawValue),
        ])
    }

    // MARK: - Manager Lifecycle

    private func ensureManager() async throws {
        if manager != nil { return }

        let kernel = try await provisionKernel()

        let imageStoreRoot = cacheRoot.appendingPathComponent("images")
        try FileManager.default.createDirectory(at: imageStoreRoot, withIntermediateDirectories: true)

        // Initialize ContainerManager with kernel, init filesystem reference, image store root,
        // and vmnet shared-mode networking for guest outbound access.
        // Requires `com.apple.developer.networking.vmnet` entitlement.
        let mgr = try await ContainerManager(
            kernel: kernel,
            initfsReference: Self.initfsReference,
            root: imageStoreRoot,
            network: ContainerManager.VmnetNetwork()
        )
        self.manager = mgr

        logger.info("Container manager initialized", metadata: [
            "kernel": .string(kernel.path.path),
            "cache": .string(cacheRoot.path),
        ])
    }

    // MARK: - Cleanup

    private func cleanupSocket(containerID: String) {
        let socketPath = socketDir.appendingPathComponent("\(containerID).sock")
        try? FileManager.default.removeItem(at: socketPath)
    }

    /// Remove generated per-container artifacts.
    private func cleanupArtifacts(_ handle: ChildHandle) {
        if let scriptDir = handle.scriptDir {
            EntrypointGenerator.cleanup(directory: scriptDir)
        }
    }

    public func stopAll() async {
        for processID in Array(hostProcesses.keys) {
            cleanupHostProcess(id: processID)
        }

        // Clean up host-side UDS files
        for containerID in containers.keys {
            cleanupSocket(containerID: containerID)
        }
        // Stop all containers (releases their EventLoopGroups)
        for (containerID, container) in containers {
            do {
                try await container.stop()
            } catch {
                logger.debug("Container stop during stopAll failed", metadata: [
                    "container_id": .string(containerID),
                    "error": .string("\(error)"),
                ])
            }
        }
        containers.removeAll()
        logger.info("ProcessController stopAll complete", metadata: [
            "manager_alive": .stringConvertible(manager != nil),
        ])
    }

    public func teardown() async {
        await stopAll()
        manager = nil
        logger.info("ProcessController teardown complete — vmnet network released")
    }

    private func cleanupManager(id: String) {
        guard var mgr = self.manager else { return }
        do {
            try mgr.delete(id)
            self.manager = mgr
        } catch {
            // Container may already be deleted
        }
    }

    private func cleanupHostProcess(id: String) {
        guard let hostProcess = hostProcesses.removeValue(forKey: id) else {
            return
        }
        hostProcess.stdoutHandle.readabilityHandler = nil
        hostProcess.stderrHandle.readabilityHandler = nil
        if hostProcess.process.isRunning {
            _ = Darwin.kill(hostProcess.process.processIdentifier, SIGKILL)
        }
        do {
            try hostProcess.stdoutHandle.close()
        } catch {}
        do {
            try hostProcess.stderrHandle.close()
        } catch {}
    }

    private func durationTimeInterval(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds) + (TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000)
    }

    private func spawnHostProcess(
        service: ServiceConfig,
        resolvedPort: Int,
        gatewayPort: Int,
        configBaseDirectory: String,
        cwd: String,
        preparedWorkspace: Bool,
        spawnStartedAt: Date
    ) throws -> ChildHandle {
        let sanitizedID = service.id.rawValue.replacingOccurrences(of: "/", with: "-")
        let processID = "aib-host-\(sanitizedID)-\(UUID().uuidString.prefix(8).lowercased())"
        let launch = hostLaunchCommand(for: service.run)
        let state = ContainerState()
        let stdoutWriter = LogWriter(
            logger: logger,
            containerID: processID,
            stream: "stdout",
            containerState: state
        )
        let stderrWriter = LogWriter(
            logger: logger,
            containerID: processID,
            stream: "stderr"
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: launch.executable)
        process.arguments = launch.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.environment = buildHostEnvironment(
            service: service,
            resolvedPort: resolvedPort,
            gatewayPort: gatewayPort,
            configBaseDirectory: configBaseDirectory,
            preparedWorkspace: preparedWorkspace
        )

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            if data.isEmpty {
                fileHandle.readabilityHandler = nil
                try? stdoutWriter.close()
                return
            }
            try? stdoutWriter.write(data)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            if data.isEmpty {
                fileHandle.readabilityHandler = nil
                try? stderrWriter.close()
                return
            }
            try? stderrWriter.write(data)
        }

        process.terminationHandler = { [logger] terminatedProcess in
            state.exitCode.withLock { $0 = terminatedProcess.terminationStatus }
            state.isAlive.withLock { $0 = false }
            logger.info("Host process exited", metadata: [
                "container_id": .string(processID),
                "exit_code": .stringConvertible(terminatedProcess.terminationStatus),
            ])
        }

        logger.info("Starting convenience host process", metadata: [
            "service_id": .string(service.id.rawValue),
            "container_id": .string(processID),
            "cwd": .string(cwd),
            "command": .string(launch.display),
        ])

        try process.run()
        hostProcesses[processID] = HostManagedProcess(
            process: process,
            stdoutHandle: stdoutPipe.fileHandleForReading,
            stderrHandle: stderrPipe.fileHandleForReading
        )

        logger.info("Convenience host process started", metadata: [
            "service_id": .string(service.id.rawValue),
            "container_id": .string(processID),
            "elapsed_ms": .stringConvertible(elapsedMilliseconds(since: spawnStartedAt)),
        ])

        return ChildHandle(
            serviceID: service.id,
            containerID: processID,
            containerIPAddress: "127.0.0.1",
            containerState: state,
            startedAt: Date(),
            resolvedPort: resolvedPort,
            backendEndpoint: BackendEndpoint(host: "localhost", port: resolvedPort),
            usesRunPhaseSignal: false,
            scriptDir: nil,
            monitorTask: nil,
            logTask: nil
        )
    }

    // MARK: - Kernel Provisioning

    /// Well-known OCI reference for the init filesystem (vminitd).
    private static let initfsReference = "ghcr.io/apple/containerization/vminit:0.26.3"

    /// Kata Containers release used as the kernel source.
    /// 3.20.0 is the latest release providing `.tar.xz` (natively supported by macOS bsdtar).
    /// Releases 3.21.0+ switched to `.tar.zst` which requires external `zstd` not available on macOS.
    private static let kataVersion = "3.20.0"
    private static let kataArchive = "kata-static-\(kataVersion)-arm64"
    private static let kataURL =
        "https://github.com/kata-containers/kata-containers/releases/download/\(kataVersion)/\(kataArchive).tar.xz"

    /// Provision a Linux kernel binary for the container runtime.
    ///
    /// Search order:
    /// 1. AIB cache: `~/.aib/container-cache/kernel/vmlinux`
    /// 2. Container CLI cache: `~/Library/Application Support/com.apple.container/kernels/vmlinux-*`
    /// 3. Auto-download from Kata Containers release
    private func provisionKernel() async throws -> Kernel {
        // 1. Check our own cache
        let kernelDir = cacheRoot.appendingPathComponent("kernel")
        let cachedKernel = kernelDir.appendingPathComponent("vmlinux")
        if FileManager.default.fileExists(atPath: cachedKernel.path) {
            logger.info("Using cached kernel", metadata: ["path": .string(cachedKernel.path)])
            return Kernel(path: cachedKernel, platform: .linuxArm, commandline: .init())
        }

        // 2. Check container CLI cache (installed by `container system start`)
        let containerSupportDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/com.apple.container/kernels")
        if FileManager.default.fileExists(atPath: containerSupportDir.path),
           let files = try? FileManager.default.contentsOfDirectory(atPath: containerSupportDir.path) {
            // Pick the newest vmlinux file
            if let kernelFile = files.filter({ $0.hasPrefix("vmlinux") }).sorted().last {
                let path = containerSupportDir.appendingPathComponent(kernelFile)
                logger.info("Using kernel from container CLI cache", metadata: [
                    "path": .string(path.path),
                ])
                // Copy to our cache for future use
                try FileManager.default.createDirectory(at: kernelDir, withIntermediateDirectories: true)
                do {
                    try FileManager.default.copyItem(at: path, to: cachedKernel)
                } catch {
                    // Non-fatal: we can use the original path
                    logger.debug("Failed to cache kernel locally", metadata: [
                        "error": .string("\(error)"),
                    ])
                }
                return Kernel(path: path, platform: .linuxArm, commandline: .init())
            }
        }

        // 3. Auto-download from Kata Containers release
        try await downloadKernel(to: cachedKernel)
        logger.info("Kernel auto-provisioned", metadata: ["path": .string(cachedKernel.path)])
        return Kernel(path: cachedKernel, platform: .linuxArm, commandline: .init())
    }

    /// Download a Linux kernel from Kata Containers and cache it locally.
    ///
    /// Pipeline:
    /// 1. Download `.tar.xz` archive via URLSession (progress via `setupProgress`)
    /// 2. Extract `vmlinux.container` (symlink) + its target to a temp directory via `/usr/bin/tar`
    /// 3. Copy the resolved binary (following symlink) to the cache destination
    ///
    /// Notes:
    /// - `vmlinux.container` inside the Kata archive is a **symlink** (e.g., → `vmlinux-6.12.42-162`).
    ///   `tar -O` cannot follow symlinks, so we extract to a directory and use `FileManager` to resolve.
    /// - Uses `.tar.xz` format (natively supported by macOS bsdtar via liblzma).
    ///   Kata 3.21.0+ only provides `.tar.zst`, which macOS cannot decompress natively.
    private func downloadKernel(to destination: URL) async throws {
        guard let url = URL(string: Self.kataURL) else {
            throw ProcessSpawnError("Invalid kernel download URL", metadata: ["url": Self.kataURL])
        }

        logger.info("Downloading Linux kernel from Kata Containers...", metadata: [
            "version": .string(Self.kataVersion),
        ])

        let kernelDir = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: kernelDir, withIntermediateDirectories: true)

        // Step 1: Download archive with progress reporting
        let delegate = KernelDownloadDelegate(progress: setupProgress, logger: logger)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let (tempArchiveURL, response) = try await session.download(from: url, delegate: delegate)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProcessSpawnError("Invalid HTTP response downloading kernel", metadata: [:])
        }
        guard httpResponse.statusCode == 200 else {
            throw ProcessSpawnError("Failed to download kernel", metadata: [
                "status_code": "\(httpResponse.statusCode)",
                "url": Self.kataURL,
            ])
        }

        // Move downloaded archive to a stable location (URLSession deletes temp file after delegate returns)
        let archivePath = kernelDir.appendingPathComponent("kata-download.tar.xz")
        try? FileManager.default.removeItem(at: archivePath)
        try FileManager.default.moveItem(at: tempArchiveURL, to: archivePath)
        defer { try? FileManager.default.removeItem(at: archivePath) }

        // Step 2: Extract vmlinux from archive
        //
        // vmlinux.container is a symlink inside the tar, so we must extract both
        // the symlink and its target to a directory, then copy with symlink resolution.
        logger.info("Extracting kernel from archive...")
        let extractDir = kernelDir.appendingPathComponent("kata-extract-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: extractDir) }

        try await runProcess(
            executablePath: "/usr/bin/tar",
            arguments: [
                "-xJf", archivePath.path,
                "-C", extractDir.path,
                "--strip-components", "1",
                "--include", "*/kata-containers/vmlinux.container",
                "--include", "*/kata-containers/vmlinux-*",
            ]
        )

        // Step 3: Resolve symlink and copy the actual kernel binary
        let extractedSymlink = extractDir
            .appendingPathComponent("opt/kata/share/kata-containers/vmlinux.container")
        let resolvedPath = extractedSymlink.resolvingSymlinksInPath()

        guard FileManager.default.fileExists(atPath: resolvedPath.path) else {
            throw ProcessSpawnError("Kernel binary not found after extraction", metadata: [
                "expected": extractedSymlink.path,
                "resolved": resolvedPath.path,
            ])
        }

        // Atomic move: copy to tmp then rename
        let tmpDest = destination.appendingPathExtension("tmp")
        try? FileManager.default.removeItem(at: tmpDest)
        try FileManager.default.copyItem(at: resolvedPath, to: tmpDest)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: tmpDest, to: destination)

        // Validate the extracted kernel
        let attrs = try FileManager.default.attributesOfItem(atPath: destination.path)
        let fileSize = attrs[.size] as? UInt64 ?? 0
        guard fileSize > 1_000_000 else {
            try? FileManager.default.removeItem(at: destination)
            throw ProcessSpawnError("Extracted kernel is too small — likely corrupt", metadata: [
                "size_bytes": "\(fileSize)",
            ])
        }

        logger.info("Kernel downloaded and cached", metadata: [
            "path": .string(destination.path),
            "size_mb": .string("\(fileSize / (1024 * 1024))"),
        ])
    }

    /// Run an executable asynchronously, capturing stderr for diagnostics.
    ///
    /// Throws `ProcessSpawnError` with stderr content if the process exits with non-zero status.
    private nonisolated func runProcess(executablePath: String, arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments

            let stderrPipe = Pipe()
            process.standardError = stderrPipe

            process.terminationHandler = { proc in
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrText = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                if proc.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: ProcessSpawnError(
                        "Process failed: \(executablePath)",
                        metadata: [
                            "exit_code": "\(proc.terminationStatus)",
                            "stderr": stderrText,
                            "arguments": arguments.joined(separator: " "),
                        ]
                    ))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Base Image Warming

    /// System packages to pre-install in base images.
    /// git: needed for npm/pnpm git dependencies.
    /// openssh-client: needed for private source auth during prepared builds.
    private static let basePackages = ["git", "openssh-client"]

    /// Ensure the base image for a runtime has system tools pre-installed and cached.
    /// On first call: starts a temporary container, installs packages, archives them to host.
    /// On subsequent calls: returns immediately (cache hit).
    private func ensureBaseImageWarmed(runtime: EntrypointGenerator.Runtime) async throws {
        let runtimeKey = runtime.rawValue
        if warmedRuntimes.contains(runtimeKey) { return }

        let archivePath = toolsArchiveDirectory(for: runtime).appendingPathComponent("tools.tar.gz")
        if FileManager.default.fileExists(atPath: archivePath.path) {
            warmedRuntimes.insert(runtimeKey)
            return
        }

        if let warmingTask = warmingTasks[runtimeKey] {
            logger.info("Awaiting in-flight base image warm", metadata: [
                "runtime": .string(runtimeKey),
                "archive": .string(archivePath.path),
            ])
            try await warmingTask.value
            return
        }

        let warmingTask = Task<Void, Error> {
            try await self.performBaseImageWarm(runtime: runtime, archivePath: archivePath)
        }
        warmingTasks[runtimeKey] = warmingTask

        do {
            try await warmingTask.value
        } catch {
            warmingTasks.removeValue(forKey: runtimeKey)
            throw error
        }
        warmingTasks.removeValue(forKey: runtimeKey)
        warmedRuntimes.insert(runtimeKey)
    }

    private func performBaseImageWarm(runtime: EntrypointGenerator.Runtime, archivePath: URL) async throws {
        let runtimeKey = runtime.rawValue

        let imageRef = baseImageReference(for: runtime)
        logger.info("Warming base image — installing system tools", metadata: [
            "runtime": .string(runtimeKey),
            "image": .string(imageRef),
            "packages": .string(Self.basePackages.joined(separator: ", ")),
        ])

        guard var mgr = self.manager else {
            throw ProcessSpawnError("Container manager not initialized", metadata: [:])
        }

        let warmID = "aib-warm-\(runtimeKey)-\(UUID().uuidString.prefix(8).lowercased())"
        let container = try await mgr.create(warmID, reference: imageRef) { config in
            config.process.arguments = ["/bin/sleep", "3600"]
            config.process.workingDirectory = "/"
            config.cpus = 2
            config.memoryInBytes = 512.mib()
        }
        self.manager = mgr

        try await container.create()
        try await container.start()

        defer {
            Task { [logger] in
                do { try await container.stop() } catch {
                    logger.debug("Warm container stop failed", metadata: ["error": .string("\(error)")])
                }
                self.cleanupManager(id: warmID)
            }
        }

        // Install packages inside the temporary container
        let packages = Self.basePackages.joined(separator: " ")
        let installScript = "apt-get update -qq && apt-get install -y -qq \(packages) && rm -rf /var/lib/apt/lists/*"
        let installProcess = try await container.exec("install", configuration: LinuxProcessConfiguration(
            arguments: ["/bin/sh", "-c", installScript],
            workingDirectory: "/"
        ))
        try await installProcess.start()
        let installStatus = try await installProcess.wait()
        guard installStatus.exitCode == 0 else {
            throw ProcessSpawnError("Failed to install base packages (exit \(installStatus.exitCode))", metadata: [
                "runtime": runtimeKey,
            ])
        }

        // Archive all files installed by the packages (dpkg -L) plus shared library dependencies (ldd)
        let archiveScript = #"""
        set -eu
        stage_root="$(mktemp -d)"
        cleanup() {
          rm -rf "$stage_root"
        }
        trap cleanup EXIT
        collect_path() {
          path="$1"
          case "$path" in
            ""|"/"|"/."|"/proc"|"/proc/"*|"/sys"|"/sys/"*|"/dev"|"/dev/"*|"/tmp"|"/tmp/"*)
              return 0
              ;;
          esac
          case "$path" in
            /*) ;;
            *) return 0 ;;
          esac
          [ -n "$path" ] || return 0
          [ -e "$path" ] || return 0
          if [ -d "$path" ] && [ ! -L "$path" ]; then
            return 0
          fi
          printf '%s\\n' "$path"
          resolved="$(readlink -f "$path" 2>/dev/null || true)"
          case "$resolved" in
            ""|"/"|"/."|"/proc"|"/proc/"*|"/sys"|"/sys/"*|"/dev"|"/dev/"*|"/tmp"|"/tmp/"*)
              resolved=""
              ;;
          esac
          if [ -n "$resolved" ] && [ "$resolved" != "$path" ] && [ -e "$resolved" ]; then
            printf '%s\\n' "$resolved"
          fi
        }
        stage_path() {
          path="$1"
          [ -e "$path" ] || return 0
          if [ -d "$path" ] && [ ! -L "$path" ]; then
            return 0
          fi
          parent="$stage_root$(dirname "$path")"
          mkdir -p "$parent"
          cp -a "$path" "$parent/"
        }
        {
          dpkg -L \#(packages) 2>/dev/null | awk '
            $0 ~ /^\// && $0 != "/" && $0 != "/." && $0 !~ /\/$/
          ' || true
          for binary in /usr/bin/git /usr/bin/ssh /usr/bin/ssh-keygen; do
            collect_path "$binary"
            ldd "$binary" 2>/dev/null | awk '
              /=>/ && $3 ~ /^\// { print $3 }
              $1 ~ /^\// { print $1 }
            ' | while IFS= read -r lib; do
              collect_path "$lib"
            done
          done
        } | sort -u | while IFS= read -r path; do
          stage_path "$path"
        done
        tar czf /tmp/tools.tar.gz -C "$stage_root" .
        """#
        let archiveStdout = BufferWriter()
        let archiveStderr = BufferWriter()
        let archiveProcess = try await container.exec("archive", configuration: LinuxProcessConfiguration(
            arguments: ["/bin/sh", "-c", archiveScript],
            workingDirectory: "/",
            stdout: archiveStdout,
            stderr: archiveStderr
        ))
        try await archiveProcess.start()
        let archiveStatus = try await archiveProcess.wait()
        guard archiveStatus.exitCode == 0 else {
            let stdoutText = archiveStdout.text
            let stderrText = archiveStderr.text
            logger.error("Failed to archive base tools", metadata: [
                "runtime": .string(runtimeKey),
                "exit_code": .stringConvertible(archiveStatus.exitCode),
                "stdout": .string(stdoutText.isEmpty ? "<empty>" : stdoutText),
                "stderr": .string(stderrText.isEmpty ? "<empty>" : stderrText),
            ])
            throw ProcessSpawnError("Failed to archive base tools (exit \(archiveStatus.exitCode))", metadata: [
                "runtime": runtimeKey,
                "stdout": stdoutText,
                "stderr": stderrText,
            ])
        }

        // Copy the archive to host cache
        let runtimeDir = toolsArchiveDirectory(for: runtime)
        try FileManager.default.createDirectory(at: runtimeDir, withIntermediateDirectories: true)
        try await container.copyOut(
            from: URL(filePath: "/tmp/tools.tar.gz"),
            to: archivePath
        )

        logger.info("Base image warmed — tools cached", metadata: [
            "runtime": .string(runtimeKey),
            "archive": .string(archivePath.path),
        ])
    }

    /// Base OCI image reference for a runtime (without AIB tools).
    private func baseImageReference(for runtime: EntrypointGenerator.Runtime) -> String {
        switch runtime {
        case .node: "docker.io/library/node:22-slim"
        case .bun: "docker.io/oven/bun:latest"
        case .python: "docker.io/library/python:3.12-slim"
        case .deno: "docker.io/denoland/deno:latest"
        case .swift: "docker.io/library/swift:6.2-noble"
        case .unknown: "docker.io/library/ubuntu:24.04"
        }
    }

    private func hostCorepackCachePath(for runtime: EntrypointGenerator.Runtime) -> String? {
        guard runtime == .node || runtime == .bun else { return nil }
        let candidates = [
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".cache/node/corepack").path,
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches/node/corepack").path,
        ]
        return candidates.first(where: { FileManager.default.fileExists(atPath: $0) })
    }

    private func hostPNPMStorePath() -> String? {
        let candidates = [
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/pnpm/store").path,
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/share/pnpm/store").path,
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".pnpm-store").path,
        ]
        return candidates.first(where: { FileManager.default.fileExists(atPath: $0) })
    }

    /// Host path to the cached tool archive for a runtime, or nil if not warmed yet.
    func toolsArchivePath(for runtime: EntrypointGenerator.Runtime) -> URL? {
        let path = toolsArchiveDirectory(for: runtime).appendingPathComponent("tools.tar.gz")
        return FileManager.default.fileExists(atPath: path.path) ? path : nil
    }

    private func toolsArchiveDirectory(for runtime: EntrypointGenerator.Runtime) -> URL {
        baseSetupDir
            .appendingPathComponent(Self.baseSetupVersion)
            .appendingPathComponent(runtime.rawValue)
    }

    // MARK: - Image Reference

    /// Determine the OCI base image reference for a service.
    ///
    /// Containerization runs Linux VMs, not Docker containers. Source code is
    /// mounted via VirtioFS to `/app`, so Dockerfiles are irrelevant here.
    /// The base image only provides the language runtime (Node, Python, etc.).
    private func imageReference(
        for service: ServiceConfig,
        runtime: EntrypointGenerator.Runtime,
        packageManager: String?
    ) throws -> String {
        switch runtime {
        case .node:
            return "docker.io/library/node:22-slim"
        case .bun:
            return "docker.io/oven/bun:latest"
        case .python:
            return "docker.io/library/python:3.12-slim"
        case .deno:
            return "docker.io/denoland/deno:latest"
        case .swift:
            return "docker.io/library/swift:6.2-noble"
        case .unknown:
            return "docker.io/library/ubuntu:24.04"
        }
    }

    // MARK: - Environment

    private func buildEnvironment(
        service: ServiceConfig,
        resolvedPort: Int,
        gatewayPort: Int,
        configBaseDirectory: String,
        runtime: EntrypointGenerator.Runtime,
        packageManager: String?,
        preparedWorkspace: Bool,
        useRepoLocalPNPMStore: Bool,
        useHostPNPMStore: Bool
    ) -> [String] {
        var env: [String: String] = [:]

        // Default PATH for Linux containers
        env["PATH"] = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

        // AIB runtime environment
        env["PORT"] = "\(resolvedPort)"
        env["AIB_SERVICE_ID"] = service.id.rawValue
        env["AIB_MOUNT_PATH"] = service.mountPath
        env["AIB_REQUEST_BASE_URL"] = "http://localhost:\(gatewayPort)\(service.mountPath)"
        env["AIB_DEV"] = "1"
        if preparedWorkspace {
            env["AIB_PREPARED_WORKSPACE"] = "1"
        }

        // Entrypoint script environment (consumed by /aib-scripts/entrypoint.sh)
        if let pm = packageManager {
            env["AIB_PACKAGE_MANAGER"] = pm
            if pm == "pnpm" {
                env["COREPACK_ENABLE_DOWNLOAD_PROMPT"] = "0"
                env["COREPACK_HOME"] = "/root/.cache/node/corepack"
                env["npm_config_prefer_offline"] = "true"
                if !preparedWorkspace, useRepoLocalPNPMStore {
                    env["PNPM_STORE_DIR"] = "/app/.pnpm-store"
                } else if !preparedWorkspace, useHostPNPMStore {
                    env["PNPM_STORE_DIR"] = "/aib-pnpm-store"
                }
            }
        }
        // Directory containing platform-specific binaries that must be isolated
        // between the macOS host and Linux guest (e.g. node_modules).
        if !preparedWorkspace, let modulesDir = EntrypointGenerator.platformModulesDir(runtime: runtime) {
            env["AIB_MODULES_DIR"] = modulesDir
        }
        // install/build/run commands are embedded directly in entrypoint.sh
        // (no environment variable serialization needed)
        env["AIB_GUEST_SOCKET_PATH"] = "/tmp/aib-svc.sock"

        // Connection file (remapped to container path)
        let connectionsFileName = "\(service.id.rawValue.replacingOccurrences(of: "/", with: "__")).json"
        let hostConnectionsPath = URL(fileURLWithPath: configBaseDirectory)
            .appendingPathComponent("generated/runtime/connections/\(connectionsFileName)")
            .standardizedFileURL.path
        if FileManager.default.fileExists(atPath: hostConnectionsPath) {
            env["AIB_CONNECTIONS_FILE"] = "/aib-runtime/connections/\(connectionsFileName)"
        }

        // MCP config for agent services (remapped to container path)
        if service.kind == .agent {
            let normalizedID = sanitizedServiceID(service.id.rawValue)
            let mcpConfigDir = "/tmp/claude-config/\(normalizedID)"
            let mcpConfigSource = "/aib-runtime/mcp/\(normalizedID)"
            env["CLAUDE_CONFIG_DIR"] = mcpConfigDir
            env["AIB_CLAUDE_CONFIG_SOURCE"] = mcpConfigSource
            env["AIB_MCP_PROJECT_CONFIG_FILE"] = "\(mcpConfigSource)/.mcp.json"
        }

        // Force line-buffered stdout for Python
        env["PYTHONUNBUFFERED"] = "1"

        // Service-specific env vars (highest priority — override defaults)
        for (key, value) in service.env {
            env[key] = value
        }

        return env.map { "\($0.key)=\($0.value)" }
    }

    private func buildPreparationEnvironment(
        service: ServiceConfig,
        runtime: EntrypointGenerator.Runtime,
        buildMode: AIBBuildMode,
        packageManager: String?,
        useRepoLocalPNPMStore: Bool,
        useHostPNPMStore: Bool,
        forwardedSSHAgentSocketPath: String?
    ) -> [String] {
        var env: [String: String] = [:]
        env["PATH"] = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        env["HOME"] = "/root"
        env["AIB_BUILD_MODE"] = buildMode.rawValue

        if let packageManager {
            env["AIB_PACKAGE_MANAGER"] = packageManager
            if packageManager == "pnpm" {
                env["COREPACK_ENABLE_DOWNLOAD_PROMPT"] = "0"
                env["COREPACK_HOME"] = "/root/.cache/node/corepack"
                env["npm_config_prefer_offline"] = "true"
                if useRepoLocalPNPMStore {
                    env["PNPM_STORE_DIR"] = "/app/.pnpm-store"
                } else if useHostPNPMStore {
                    env["PNPM_STORE_DIR"] = "/aib-pnpm-store"
                }
            }
        }
        if let modulesDir = EntrypointGenerator.platformModulesDir(runtime: runtime) {
            env["AIB_MODULES_DIR"] = modulesDir
        }
        if let forwardedSSHAgentSocketPath {
            env["AIB_SSH_AUTH_SOCK"] = forwardedSSHAgentSocketPath
        }
        for (key, value) in service.env {
            env[key] = value
        }
        return env.map { "\($0.key)=\($0.value)" }
    }

    private func buildHostEnvironment(
        service: ServiceConfig,
        resolvedPort: Int,
        gatewayPort: Int,
        configBaseDirectory: String,
        preparedWorkspace: Bool
    ) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = hostExecutionPATH()
        env["PORT"] = "\(resolvedPort)"
        env["AIB_SERVICE_ID"] = service.id.rawValue
        env["AIB_MOUNT_PATH"] = service.mountPath
        env["AIB_REQUEST_BASE_URL"] = "http://127.0.0.1:\(gatewayPort)\(service.mountPath)"
        env["AIB_DEV"] = "1"
        if preparedWorkspace {
            env["AIB_PREPARED_WORKSPACE"] = "1"
        }

        let connectionsFileName = "\(service.id.rawValue.replacingOccurrences(of: "/", with: "__")).json"
        let hostConnectionsPath = URL(fileURLWithPath: configBaseDirectory)
            .appendingPathComponent("generated/runtime/connections/\(connectionsFileName)")
            .standardizedFileURL.path
        if FileManager.default.fileExists(atPath: hostConnectionsPath) {
            env["AIB_CONNECTIONS_FILE"] = hostConnectionsPath
        }

        for (key, value) in service.env {
            env[key] = value
        }
        return env
    }

    private func buildHostBuildEnvironment(
        service: ServiceConfig,
        runtime: EntrypointGenerator.Runtime,
        packageManager: String?
    ) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = hostExecutionPATH()
        env["AIB_BUILD_MODE"] = AIBBuildMode.convenience.rawValue
        if let packageManager {
            env["AIB_PACKAGE_MANAGER"] = packageManager
            if packageManager == "pnpm" {
                env["COREPACK_ENABLE_DOWNLOAD_PROMPT"] = "0"
                env["npm_config_prefer_offline"] = "true"
            }
        }
        if let modulesDir = EntrypointGenerator.platformModulesDir(runtime: runtime) {
            env["AIB_MODULES_DIR"] = modulesDir
        }
        for (key, value) in service.env {
            env[key] = value
        }
        return env
    }

    private func hostExecutionPATH() -> String {
        let candidates = [
            "\(NSHomeDirectory())/.local/bin",
            "\(NSHomeDirectory())/.npm-global/bin",
            "\(NSHomeDirectory())/Library/pnpm",
            "\(NSHomeDirectory())/.pnpm",
            "\(NSHomeDirectory())/.swiftly/bin",
            "\(NSHomeDirectory())/google-cloud-sdk/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]

        var ordered: [String] = []
        var seen = Set<String>()
        let existing = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map(String.init) ?? []

        for path in existing + candidates {
            let expanded = NSString(string: path).expandingTildeInPath
            guard !expanded.isEmpty else { continue }
            if seen.insert(expanded).inserted {
                ordered.append(expanded)
            }
        }
        return ordered.joined(separator: ":")
    }

    private func prepareNodeWorkspaceForConvenienceMode(
        service: ServiceConfig,
        repoRoot: String,
        workspaceRoot: String,
        buildMode: AIBBuildMode,
        sourceCredentials: [AIBSourceCredential],
        sourceDependencies: [AIBSourceDependencyFinding],
        convenience: AIBConvenienceOptions?,
        prepareStartedAt: Date
    ) throws -> String {
        let runtime = EntrypointGenerator.detectRuntime(service: service)
        let sanitizedID = service.id.rawValue.replacingOccurrences(of: "/", with: "-")
        let buildRoot = URL(fileURLWithPath: workspaceRoot)
            .appendingPathComponent(".aib/state/local-build/\(sanitizedID)")
            .standardizedFileURL
        let stagedWorkspaceRoot = buildRoot.appendingPathComponent("workspace")
        let preparedWorkspaceManifestURL = buildRoot.appendingPathComponent("prepared-workspace.json")
        let fileManager = FileManager.default
        let convenienceOptions = resolvedConvenienceOptions(for: buildMode, convenience: convenience)
        let fingerprintStartedAt = Date()
        let preparedWorkspaceFingerprint = try computePreparedWorkspaceFingerprint(
            service: service,
            repoRoot: repoRoot,
            buildMode: buildMode,
            sourceDependencies: sourceDependencies,
            sourceCredentials: sourceCredentials,
            convenience: convenienceOptions
        )
        logger.info("Prepared workspace fingerprint computed", metadata: [
            "service_id": .string(service.id.rawValue),
            "elapsed_ms": .stringConvertible(elapsedMilliseconds(since: fingerprintStartedAt)),
            "total_elapsed_ms": .stringConvertible(elapsedMilliseconds(since: prepareStartedAt)),
        ])

        if isPreparedWorkspaceCacheReusable(
            stagedWorkspaceRoot: stagedWorkspaceRoot,
            manifestURL: preparedWorkspaceManifestURL,
            expectedFingerprint: preparedWorkspaceFingerprint
        ) {
            logger.info("Reusing prepared Node workspace cache", metadata: [
                "service_id": .string(service.id.rawValue),
                "build_mode": .string(buildMode.rawValue),
                "staged_workspace": .string(stagedWorkspaceRoot.path),
                "total_elapsed_ms": .stringConvertible(elapsedMilliseconds(since: prepareStartedAt)),
            ])
            return stagedWorkspaceRoot.path
        }

        if fileManager.fileExists(atPath: buildRoot.path) {
            try fileManager.removeItem(at: buildRoot)
        }
        try fileManager.createDirectory(at: buildRoot, withIntermediateDirectories: true)

        let stageCopyStartedAt = Date()
        try stageWorkspaceCopy(from: repoRoot, to: stagedWorkspaceRoot)
        logger.info("Workspace staged for host builder", metadata: [
            "service_id": .string(service.id.rawValue),
            "staged_workspace": .string(stagedWorkspaceRoot.path),
            "elapsed_ms": .stringConvertible(elapsedMilliseconds(since: stageCopyStartedAt)),
            "total_elapsed_ms": .stringConvertible(elapsedMilliseconds(since: prepareStartedAt)),
        ])

        var effectiveService = service
        if let normalizedInstallCommand = normalizedConvenienceInstallCommand(
            for: service,
            runtime: runtime,
            cwd: stagedWorkspaceRoot.path
        ) {
            effectiveService.install = normalizedInstallCommand
            logger.info("Using normalized install command for convenience build", metadata: [
                "service_id": .string(service.id.rawValue),
                "resolved": .string(normalizedInstallCommand.joined(separator: " ")),
            ])
        }
        if let inferredBuildCommand = inferredPreparedWorkspaceBuildCommand(
            for: service,
            runtime: runtime,
            cwd: stagedWorkspaceRoot.path
        ) {
            effectiveService.build = inferredBuildCommand
            logger.info("Using inferred build command for prepared workspace", metadata: [
                "service_id": .string(service.id.rawValue),
                "resolved": .string(inferredBuildCommand.joined(separator: " ")),
            ])
        }

        let packageManager = EntrypointGenerator.detectPackageManager(service: effectiveService)
        let hostBuildID = "aib-host-build-\(sanitizedID)-\(UUID().uuidString.prefix(8).lowercased())"
        let environment = buildHostBuildEnvironment(
            service: effectiveService,
            runtime: runtime,
            packageManager: packageManager
        )

        logger.info("Preparing Node workspace on host (convenience mode)", metadata: [
            "service_id": .string(service.id.rawValue),
            "build_mode": .string(buildMode.rawValue),
            "repo_root": .string(repoRoot),
            "staged_workspace": .string(stagedWorkspaceRoot.path),
            "total_elapsed_ms": .stringConvertible(elapsedMilliseconds(since: prepareStartedAt)),
        ])

        if let installCommand = effectiveService.install {
            let phaseStartedAt = Date()
            logger.info("[aib] Installing dependencies: \(shellCommand(installCommand))", metadata: [
                "container_id": .string(hostBuildID),
                "stream": .string("stdout"),
            ])
            try runHostCommand(
                installCommand,
                cwd: stagedWorkspaceRoot.path,
                environment: environment,
                processID: hostBuildID
            )
            logger.info("[aib] Install phase completed (duration_ms=\(elapsedMilliseconds(since: phaseStartedAt)))", metadata: [
                "container_id": .string(hostBuildID),
                "stream": .string("stdout"),
            ])
        }

        if let buildCommand = effectiveService.build {
            let phaseStartedAt = Date()
            logger.info("[aib] Building: \(shellCommand(buildCommand))", metadata: [
                "container_id": .string(hostBuildID),
                "stream": .string("stdout"),
            ])
            try runHostCommand(
                buildCommand,
                cwd: stagedWorkspaceRoot.path,
                environment: environment,
                processID: hostBuildID
            )
            logger.info("[aib] Build phase completed (duration_ms=\(elapsedMilliseconds(since: phaseStartedAt)))", metadata: [
                "container_id": .string(hostBuildID),
                "stream": .string("stdout"),
            ])
        }

        if let pruneCommand = runtimeDependencyPruneCommand(packageManager: packageManager) {
            let phaseStartedAt = Date()
            logger.info("[aib] Pruning runtime dependencies: \(shellCommand(pruneCommand))", metadata: [
                "container_id": .string(hostBuildID),
                "stream": .string("stdout"),
            ])
            try runHostCommand(
                pruneCommand,
                cwd: stagedWorkspaceRoot.path,
                environment: environment,
                processID: hostBuildID
            )
            logger.info("[aib] Runtime dependency prune completed (duration_ms=\(elapsedMilliseconds(since: phaseStartedAt)))", metadata: [
                "container_id": .string(hostBuildID),
                "stream": .string("stdout"),
            ])
        }

        try writePreparedWorkspaceCacheManifest(
            at: preparedWorkspaceManifestURL,
            fingerprint: preparedWorkspaceFingerprint
        )
        logger.info("Prepared Node workspace ready", metadata: [
            "service_id": .string(service.id.rawValue),
            "staged_workspace": .string(stagedWorkspaceRoot.path),
            "total_elapsed_ms": .stringConvertible(elapsedMilliseconds(since: prepareStartedAt)),
        ])

        return stagedWorkspaceRoot.path
    }

    private func normalizedConvenienceInstallCommand(
        for service: ServiceConfig,
        runtime: EntrypointGenerator.Runtime,
        cwd: String
    ) -> [String]? {
        guard runtime == .node else {
            return service.install
        }
        if let install = service.install {
            let flattened = install.joined(separator: " ")
            if flattened.contains("pnpm install") {
                return ["pnpm", "install"]
            }
            if flattened.contains("npm install") {
                return ["npm", "install"]
            }
            if flattened.contains("yarn install") {
                return ["yarn", "install"]
            }
            if flattened.contains("bun install") {
                return ["bun", "install"]
            }
            return install
        }

        guard FileManager.default.fileExists(atPath: URL(fileURLWithPath: cwd).appendingPathComponent("package.json").path),
              let packageManager = EntrypointGenerator.detectPackageManager(service: service)
        else {
            return nil
        }
        switch packageManager {
        case "pnpm":
            return ["pnpm", "install"]
        case "yarn":
            return ["yarn", "install"]
        case "bun":
            return ["bun", "install"]
        default:
            return ["npm", "install"]
        }
    }

    private func runtimeDependencyPruneCommand(packageManager: String?) -> [String]? {
        switch packageManager {
        case "pnpm":
            return ["pnpm", "prune", "--prod"]
        case "npm":
            return ["npm", "prune", "--omit=dev"]
        default:
            return nil
        }
    }

    private func hostLaunchCommand(for argv: [String]) -> (executable: String, arguments: [String], display: String) {
        if argv.count >= 3, argv[0] == "/bin/sh", argv[1] == "-lc" {
            let command = argv[2]
            return (
                executable: "/bin/sh",
                arguments: ["-lc", "exec \(command)"],
                display: "/bin/sh -lc exec \(command)"
            )
        }
        if let executable = argv.first, executable.contains("/") {
            return (
                executable: executable,
                arguments: Array(argv.dropFirst()),
                display: shellCommand(argv)
            )
        }
        if let command = argv.first, let resolvedExecutable = resolveHostExecutable(command) {
            return (
                executable: resolvedExecutable,
                arguments: Array(argv.dropFirst()),
                display: shellCommand([resolvedExecutable] + Array(argv.dropFirst()))
            )
        }
        return (
            executable: "/usr/bin/env",
            arguments: argv,
            display: shellCommand(argv)
        )
    }

    private func resolveHostExecutable(_ command: String) -> String? {
        for directory in hostExecutionPATH().split(separator: ":").map(String.init) {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(command).path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private func runHostCommand(
        _ argv: [String],
        cwd: String,
        environment: [String: String],
        processID: String
    ) throws {
        let launch = hostLaunchCommand(for: argv)
        let stdoutWriter = LogWriter(
            logger: logger,
            containerID: processID,
            stream: "stdout"
        )
        let stderrWriter = LogWriter(
            logger: logger,
            containerID: processID,
            stream: "stderr"
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: launch.executable)
        process.arguments = launch.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            if data.isEmpty {
                fileHandle.readabilityHandler = nil
                try? stdoutWriter.close()
                return
            }
            try? stdoutWriter.write(data)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            if data.isEmpty {
                fileHandle.readabilityHandler = nil
                try? stderrWriter.close()
                return
            }
            try? stderrWriter.write(data)
        }

        try process.run()
        process.waitUntilExit()
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        try? stdoutWriter.close()
        try? stderrWriter.close()

        guard process.terminationStatus == 0 else {
            throw BuildPreparationError("Host build command failed", metadata: [
                "command": shellCommand(argv),
                "cwd": cwd,
                "exit_code": "\(process.terminationStatus)",
            ])
        }
    }

    private func resolvedConvenienceOptions(
        for buildMode: AIBBuildMode,
        convenience: AIBConvenienceOptions?
    ) -> AIBConvenienceOptions {
        guard buildMode == .convenience else {
            return AIBConvenienceOptions(
                useHostCorepackCache: false,
                useHostPNPMStore: false,
                useRepoLocalPNPMStore: false
            )
        }
        return convenience ?? AIBConvenienceOptions()
    }

    private func computePreparedWorkspaceFingerprint(
        service: ServiceConfig,
        repoRoot: String,
        buildMode: AIBBuildMode,
        sourceDependencies: [AIBSourceDependencyFinding],
        sourceCredentials: [AIBSourceCredential],
        convenience: AIBConvenienceOptions
    ) throws -> String {
        var lines: [String] = []
        lines.append("cache-version:\(Self.preparedWorkspaceCacheVersion)")
        lines.append("base-setup-version:\(Self.baseSetupVersion)")
        lines.append("service-id:\(service.id.rawValue)")
        lines.append("build-mode:\(buildMode.rawValue)")
        lines.append("convenience:host-corepack=\(convenience.useHostCorepackCache)")
        lines.append("convenience:host-pnpm-store=\(convenience.useHostPNPMStore)")
        lines.append("convenience:repo-pnpm-store=\(convenience.useRepoLocalPNPMStore)")
        lines.append("install:\(service.install?.joined(separator: "\u{1f}") ?? "")")
        lines.append("build:\(service.build?.joined(separator: "\u{1f}") ?? "")")
        lines.append("run:\(service.run.joined(separator: "\u{1f}"))")

        for key in service.env.keys.sorted() {
            lines.append("env:\(key)=\(service.env[key] ?? "")")
        }

        for dependency in sourceDependencies.sorted(by: {
            ($0.host, $0.sourceFile, $0.requirement) < ($1.host, $1.sourceFile, $1.requirement)
        }) {
            lines.append("dependency:\(dependency.host)|\(dependency.sourceFile)|\(dependency.requirement)")
        }

        for credential in sourceCredentials.sorted(by: {
            ($0.host, $0.type.rawValue) < ($1.host, $1.type.rawValue)
        }) {
            lines.append(
                "credential:\(credential.host)|\(credential.type.rawValue)|\(credential.localPrivateKeyPath ?? "")|\(credential.localPrivateKeyPassphraseEnv ?? "")|\(credential.localKnownHostsPath ?? "")|\(credential.localAccessTokenEnv ?? "")"
            )
        }

        try appendPreparedWorkspaceSnapshot(from: repoRoot, to: &lines)

        let material = lines.joined(separator: "\n")
        let digest = SHA256.hash(data: Data(material.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func appendPreparedWorkspaceSnapshot(from repoRoot: String, to lines: inout [String]) throws {
        let fileManager = FileManager.default
        let rootURL = URL(fileURLWithPath: repoRoot).standardizedFileURL
        let rootPath = rootURL.path
        let resourceKeys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .contentModificationDateKey,
            .fileSizeKey,
        ]

        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [],
            errorHandler: { [logger] url, error in
                logger.debug("Prepared workspace fingerprint skipped unreadable path", metadata: [
                    "path": .string(url.path),
                    "error": .string("\(error)"),
                ])
                return true
            }
        ) else {
            throw BuildPreparationError("Failed to enumerate Node workspace for cache fingerprint", metadata: [
                "repo_root": repoRoot,
            ])
        }

        for case let fileURL as URL in enumerator {
            let relativePath = String(fileURL.path.dropFirst(rootPath.count + 1))
            let resourceValues = try fileURL.resourceValues(forKeys: resourceKeys)
            let isDirectory = resourceValues.isDirectory ?? false

            if shouldIgnorePreparedWorkspacePath(relativePath, isDirectory: isDirectory) {
                if isDirectory {
                    enumerator.skipDescendants()
                }
                continue
            }

            if isDirectory {
                lines.append("dir:\(relativePath)")
                continue
            }

            if resourceValues.isSymbolicLink == true {
                let destination = try fileManager.destinationOfSymbolicLink(atPath: fileURL.path)
                lines.append("symlink:\(relativePath)|\(destination)")
                continue
            }

            guard resourceValues.isRegularFile == true else {
                continue
            }

            let fileSize = resourceValues.fileSize ?? 0
            let modificationInterval = resourceValues.contentModificationDate?.timeIntervalSince1970 ?? 0
            lines.append("file:\(relativePath)|\(fileSize)|\(modificationInterval)")
        }
    }

    private func shouldIgnorePreparedWorkspacePath(_ relativePath: String, isDirectory: Bool) -> Bool {
        let components = relativePath.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return false }
        if components.contains(".git") || components.contains("node_modules") || components.contains(".pnpm-store") {
            return true
        }
        if !isDirectory, components.last == ".DS_Store" {
            return true
        }
        return false
    }

    private func isPreparedWorkspaceCacheReusable(
        stagedWorkspaceRoot: URL,
        manifestURL: URL,
        expectedFingerprint: String
    ) -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: stagedWorkspaceRoot.path),
              fileManager.fileExists(atPath: manifestURL.path)
        else {
            return false
        }

        do {
            let manifestData = try Data(contentsOf: manifestURL)
            let manifest = try JSONDecoder().decode(PreparedWorkspaceCacheManifest.self, from: manifestData)
            return manifest.version == Self.preparedWorkspaceCacheVersion
                && manifest.fingerprint == expectedFingerprint
        } catch {
            logger.debug("Prepared workspace cache manifest is invalid", metadata: [
                "path": .string(manifestURL.path),
                "error": .string("\(error)"),
            ])
            return false
        }
    }

    private func writePreparedWorkspaceCacheManifest(at url: URL, fingerprint: String) throws {
        let manifest = PreparedWorkspaceCacheManifest(
            version: Self.preparedWorkspaceCacheVersion,
            fingerprint: fingerprint
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: url, options: .atomic)
    }

    private func stageWorkspaceCopy(from sourceRoot: String, to destinationRoot: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destinationRoot.path) {
            try fileManager.removeItem(at: destinationRoot)
        }
        try fileManager.copyItem(at: URL(fileURLWithPath: sourceRoot), to: destinationRoot)

        let excludedPaths = [
            destinationRoot.appendingPathComponent(".git"),
            destinationRoot.appendingPathComponent("node_modules"),
            destinationRoot.appendingPathComponent(".pnpm-store"),
        ]
        for excludedPath in excludedPaths where fileManager.fileExists(atPath: excludedPath.path) {
            try fileManager.removeItem(at: excludedPath)
        }
    }

    private func resolvedPreparedWorkspaceRunCommand(
        for service: ServiceConfig,
        runtime: EntrypointGenerator.Runtime,
        cwd: String,
        preparedWorkspace: Bool
    ) -> [String]? {
        guard preparedWorkspace, runtime == .node else {
            return nil
        }
        guard let startCommand = preparedWorkspaceStartCommand(for: service.run) else {
            return nil
        }
        let packageURL = URL(fileURLWithPath: cwd).appendingPathComponent("package.json")
        guard FileManager.default.fileExists(atPath: packageURL.path) else {
            return nil
        }

        guard let scripts = nodePackageScripts(at: cwd),
              let startScript = scripts["start"],
              !startScript.isEmpty
        else {
            return nil
        }
        _ = startCommand
        return ["/bin/sh", "-lc", startScript]
    }

    private func inferredPreparedWorkspaceBuildCommand(
        for service: ServiceConfig,
        runtime: EntrypointGenerator.Runtime,
        cwd: String
    ) -> [String]? {
        guard runtime == .node, service.build == nil else {
            return nil
        }
        guard let packageManager = EntrypointGenerator.detectPackageManager(service: service),
              let scripts = nodePackageScripts(at: cwd),
              scripts["build"] != nil
        else {
            return nil
        }

        switch packageManager {
        case "pnpm":
            return ["pnpm", "build"]
        case "yarn":
            return ["yarn", "build"]
        case "bun":
            return ["bun", "run", "build"]
        default:
            return ["npm", "run", "build"]
        }
    }

    private func preparedWorkspaceStartCommand(for runCommand: [String]) -> [String]? {
        switch runCommand {
        case ["pnpm", "dev"]:
            return ["pnpm", "start"]
        case ["yarn", "dev"]:
            return ["yarn", "start"]
        case ["npm", "run", "dev"]:
            return ["npm", "run", "start"]
        case ["bun", "run", "dev"]:
            return ["bun", "run", "start"]
        default:
            return nil
        }
    }

    private func nodePackageScripts(at cwd: String) -> [String: String]? {
        let packageURL = URL(fileURLWithPath: cwd).appendingPathComponent("package.json")
        guard FileManager.default.fileExists(atPath: packageURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: packageURL)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let scripts = json["scripts"] as? [String: String]
            else {
                return nil
            }
            return scripts
        } catch {
            logger.debug("Failed to inspect package.json scripts", metadata: [
                "path": .string(packageURL.path),
                "error": .string("\(error)"),
            ])
            return nil
        }
    }

    private func materializeLocalSourceAuth(
        authRoot: URL,
        dependencies: [AIBSourceDependencyFinding],
        credentials: [AIBSourceCredential]
    ) throws -> String? {
        var selectedRequirement: (finding: AIBSourceDependencyFinding, credential: AIBSourceCredential)?
        for finding in dependencies {
            guard let credential = AIBSourceDependencyAnalyzer.matchingLocalCredential(for: finding, in: credentials) else {
                throw BuildPreparationError("Missing local source credential for private dependency", metadata: [
                    "host": finding.host,
                    "source_file": finding.sourceFile,
                    "requirement": finding.requirement,
                ])
            }
            if localSourceMirrorPlan(for: finding) != nil,
               credential.host.caseInsensitiveCompare("github.com") == .orderedSame,
               try resolvedGitHubAccessToken(for: credential) != nil
            {
                continue
            }
            selectedRequirement = (finding, credential)
            break
        }

        guard let selectedRequirement else { return nil }
        let credential = selectedRequirement.credential
        guard credential.type == .ssh else {
            return nil
        }
        guard let privateKeyPath = credential.localPrivateKeyPath, !privateKeyPath.isEmpty else {
            throw BuildPreparationError("Local source credential is missing private key path", metadata: [
                "host": credential.host,
            ])
        }

        let privateKeyURL = URL(fileURLWithPath: privateKeyPath).standardizedFileURL
        guard FileManager.default.fileExists(atPath: privateKeyURL.path) else {
            throw BuildPreparationError("Local source private key file not found", metadata: [
                "host": credential.host,
                "path": privateKeyURL.path,
            ])
        }

        try FileManager.default.createDirectory(at: authRoot, withIntermediateDirectories: true)

        let authPrivateKeyPath = authRoot.appendingPathComponent("id_ed25519")
        try materializeLocalPrivateKey(
            from: privateKeyURL,
            to: authPrivateKeyPath,
            credential: credential
        )

        let knownHostsPath = authRoot.appendingPathComponent("known_hosts")
        if let localKnownHostsPath = credential.localKnownHostsPath, !localKnownHostsPath.isEmpty {
            let localKnownHostsURL = URL(fileURLWithPath: localKnownHostsPath).standardizedFileURL
            guard FileManager.default.fileExists(atPath: localKnownHostsURL.path) else {
                throw BuildPreparationError("Local source known_hosts file not found", metadata: [
                    "host": credential.host,
                    "path": localKnownHostsURL.path,
                ])
            }
            try FileManager.default.copyItem(at: localKnownHostsURL, to: knownHostsPath)
        } else if let defaultKnownHosts = AIBSourceDependencyAnalyzer.defaultKnownHosts(for: credential.host) {
            try defaultKnownHosts.write(to: knownHostsPath, atomically: true, encoding: .utf8)
        }

        return authRoot.path
    }

    private func materializeLocalSourceMirrors(
        mirrorsRoot: URL,
        authRoot: URL,
        dependencies: [AIBSourceDependencyFinding],
        credentials: [AIBSourceCredential]
    ) throws -> String? {
        let plans = dependencies.compactMap { finding -> LocalSourceMirrorPlan? in
            guard let credential = AIBSourceDependencyAnalyzer.matchingLocalCredential(for: finding, in: credentials) else {
                return nil
            }
            guard let plan = localSourceMirrorPlan(for: finding) else {
                return nil
            }
            return LocalSourceMirrorPlan(finding: finding, credential: credential, plan: plan)
        }

        guard !plans.isEmpty else { return nil }

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: mirrorsRoot.path) {
            try fileManager.removeItem(at: mirrorsRoot)
        }
        try fileManager.createDirectory(at: mirrorsRoot, withIntermediateDirectories: true)

        var rewriteLines: [String] = []
        for mirror in plans {
            let gitEnvironment = try resolvedHostMirrorGitEnvironment(
                credential: mirror.credential,
                authRoot: authRoot
            )
            let remoteURL: String
            if mirror.plan.host.caseInsensitiveCompare("github.com") == .orderedSame,
               gitEnvironment["GIT_CONFIG_KEY_0"]?.contains("x-access-token:") == true
            {
                remoteURL = "https://github.com/\(mirror.plan.repositoryPath).git"
            } else if mirror.credential.type == .githubToken {
                remoteURL = "https://github.com/\(mirror.plan.repositoryPath).git"
            } else {
                remoteURL = mirror.plan.remoteURL
            }
            let mirrorURL = mirrorsRoot
                .appendingPathComponent(mirror.plan.host)
                .appendingPathComponent(mirror.plan.repositoryPath + ".git")
            try fileManager.createDirectory(
                at: mirrorURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            try updateMirrorRepository(
                at: mirrorURL,
                remoteURL: remoteURL,
                environment: gitEnvironment,
                host: mirror.credential.host
            )

            let mountedMirrorURL = "file:///aib-source-mirrors/\(mirror.plan.host)/\(mirror.plan.repositoryPath).git"
            for prefix in mirror.plan.rewritePrefixes {
                rewriteLines.append("\(mountedMirrorURL)\t\(prefix)")
            }
        }

        if !rewriteLines.isEmpty {
            let rewritesURL = mirrorsRoot.appendingPathComponent(".git-rewrites")
            try rewriteLines.joined(separator: "\n").appending("\n").write(
                to: rewritesURL,
                atomically: true,
                encoding: .utf8
            )
        }

        return mirrorsRoot.path
    }

    private struct LocalSourceMirrorPlan {
        let finding: AIBSourceDependencyFinding
        let credential: AIBSourceCredential
        let plan: ParsedSourceRepository
    }

    private struct ParsedSourceRepository {
        let host: String
        let repositoryPath: String
        let remoteURL: String
        let rewritePrefixes: [String]
    }

    private func materializeLocalPrivateKey(
        from sourcePrivateKeyURL: URL,
        to destinationPrivateKeyURL: URL,
        credential: AIBSourceCredential
    ) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destinationPrivateKeyURL.path) {
            try fileManager.removeItem(at: destinationPrivateKeyURL)
        }
        try fileManager.copyItem(at: sourcePrivateKeyURL, to: destinationPrivateKeyURL)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: destinationPrivateKeyURL.path
        )

        let blankPassphraseProbe = try inspectSSHPrivateKey(
            at: destinationPrivateKeyURL,
            passphrase: "",
            host: credential.host
        )
        if blankPassphraseProbe.exitCode == 0 {
            return
        }

        guard let passphrase = try resolvedLocalPrivateKeyPassphrase(for: credential) else {
            if sshAgentCanAuthenticatePrivateRepositories() {
                if fileManager.fileExists(atPath: destinationPrivateKeyURL.path) {
                    try fileManager.removeItem(at: destinationPrivateKeyURL)
                }
                return
            }
            if looksLikePassphraseProtected(stderr: blankPassphraseProbe.stderr) {
                throw BuildPreparationError(
                    "Local source private key is passphrase-protected; configure localPrivateKeyPassphraseEnv or unlock the key in ssh-agent for non-interactive local builds",
                    metadata: [
                        "host": credential.host,
                        "path": sourcePrivateKeyURL.path,
                    ]
                )
            }
            throw BuildPreparationError("Local source private key could not be validated", metadata: [
                "host": credential.host,
                "path": sourcePrivateKeyURL.path,
                "stderr": blankPassphraseProbe.stderr,
            ])
        }

        let decryptResult = try reencryptSSHPrivateKeyWithoutPassphrase(
            at: destinationPrivateKeyURL,
            oldPassphrase: passphrase,
            host: credential.host
        )
        guard decryptResult.exitCode == 0 else {
            throw BuildPreparationError(
                "Failed to decrypt local source private key with configured passphrase",
                metadata: [
                    "host": credential.host,
                    "env": credential.localPrivateKeyPassphraseEnv ?? "",
                    "stderr": decryptResult.stderr,
                ]
            )
        }

        let decryptedProbe = try inspectSSHPrivateKey(
            at: destinationPrivateKeyURL,
            passphrase: "",
            host: credential.host
        )
        guard decryptedProbe.exitCode == 0 else {
            throw BuildPreparationError("Decrypted local source private key could not be validated", metadata: [
                "host": credential.host,
                "stderr": decryptedProbe.stderr,
            ])
        }
    }

    private func resolvedLocalPrivateKeyPassphrase(
        for credential: AIBSourceCredential
    ) throws -> String? {
        guard let envName = credential.localPrivateKeyPassphraseEnv?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !envName.isEmpty
        else {
            return nil
        }
        if let passphrase = ProcessInfo.processInfo.environment[envName],
           !passphrase.isEmpty
        {
            return passphrase
        }
        if availableSSHAgentSocketPath() != nil {
            return nil
        }
        throw BuildPreparationError(
            "Local source private key passphrase environment variable is not set",
            metadata: [
                "host": credential.host,
                "env": envName,
            ]
        )
    }

    private func resolvedHostMirrorGitEnvironment(
        credential: AIBSourceCredential,
        authRoot: URL
    ) throws -> [String: String] {
        if let token = try resolvedGitHubAccessToken(for: credential) {
            let encodedToken = percentEncodedGitCredentialComponent(token)
            return [
                "GIT_CONFIG_COUNT": "1",
                "GIT_CONFIG_KEY_0": "url.https://x-access-token:\(encodedToken)@github.com/.insteadOf",
                "GIT_CONFIG_VALUE_0": "https://github.com/",
            ]
        }

        let knownHostsPath = authRoot.appendingPathComponent("known_hosts").path
        let privateKeyPath = authRoot.appendingPathComponent("id_ed25519").path

        if FileManager.default.fileExists(atPath: privateKeyPath) {
            let sshCommand = [
                "ssh",
                "-i", privateKeyPath,
                "-o", "IdentitiesOnly=yes",
                "-o", "UserKnownHostsFile=\(knownHostsPath)",
                "-o", "StrictHostKeyChecking=yes",
            ].joined(separator: " ")
            return ["GIT_SSH_COMMAND": sshCommand]
        }

        if let socketPath = availableSSHAgentSocketPath() {
            let sshCommand = [
                "ssh",
                "-o", "IdentityAgent=\(socketPath)",
                "-o", "UserKnownHostsFile=\(knownHostsPath)",
                "-o", "StrictHostKeyChecking=yes",
            ].joined(separator: " ")
            return [
                "SSH_AUTH_SOCK": socketPath,
                "GIT_SSH_COMMAND": sshCommand,
            ]
        }

        return [:]
    }

    private func resolvedGitHubAccessToken(
        for credential: AIBSourceCredential
    ) throws -> String? {
        guard credential.host.caseInsensitiveCompare("github.com") == .orderedSame else {
            return nil
        }

        if let environmentKey = credential.localAccessTokenEnv?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !environmentKey.isEmpty
        {
            if let token = ProcessInfo.processInfo.environment[environmentKey],
               !token.isEmpty
            {
                return token
            }
        } else if credential.type == .githubToken {
            throw BuildPreparationError("Local GitHub token credential is missing access token environment key", metadata: [
                "host": credential.host,
            ])
        }

        for environmentKey in ["GITHUB_TOKEN", "GH_TOKEN"] {
            if let token = ProcessInfo.processInfo.environment[environmentKey],
               !token.isEmpty
            {
                return token
            }
        }

        if let token = try resolvedGitHubCLIToken(host: credential.host) {
            return token
        }

        if credential.type == .githubToken {
            throw BuildPreparationError("Local GitHub token environment variable is not set", metadata: [
                "host": credential.host,
                "env": credential.localAccessTokenEnv ?? "",
            ])
        }

        return nil
    }

    private func resolvedGitHubCLIToken(host: String) throws -> String? {
        guard host.caseInsensitiveCompare("github.com") == .orderedSame else {
            return nil
        }

        let candidatePaths = [
            "/opt/homebrew/bin/gh",
            "/usr/local/bin/gh",
            "/usr/bin/gh",
        ]

        let executablePath = candidatePaths.first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
        guard let executablePath else {
            return nil
        }

        let result = try runProcessSynchronously(
            executablePath: executablePath,
            arguments: ["auth", "token", "-h", host]
        )
        guard result.exitCode == 0 else {
            return nil
        }

        let token = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    private func updateMirrorRepository(
        at mirrorURL: URL,
        remoteURL: String,
        environment: [String: String],
        host: String
    ) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: mirrorURL.path) {
            let updateResult = try runProcessSynchronously(
                executablePath: "/usr/bin/git",
                arguments: ["-C", mirrorURL.path, "remote", "update", "--prune"],
                environment: environment
            )
            guard updateResult.exitCode == 0 else {
                throw BuildPreparationError("Failed to update local source mirror", metadata: [
                    "host": host,
                    "remote_url": remoteURL,
                    "mirror_path": mirrorURL.path,
                    "stderr": updateResult.stderr,
                ])
            }
            return
        }

        let cloneResult = try runProcessSynchronously(
            executablePath: "/usr/bin/git",
            arguments: ["clone", "--mirror", remoteURL, mirrorURL.path],
            environment: environment
        )
        guard cloneResult.exitCode == 0 else {
            throw BuildPreparationError("Failed to create local source mirror", metadata: [
                "host": host,
                "remote_url": remoteURL,
                "mirror_path": mirrorURL.path,
                "stderr": cloneResult.stderr,
            ])
        }
    }

    private func localSourceMirrorPlan(
        for finding: AIBSourceDependencyFinding
    ) -> ParsedSourceRepository? {
        let rawRequirement = finding.requirement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawRequirement.isEmpty else { return nil }

        let requirementWithoutFragment: String
        if let fragmentSeparator = rawRequirement.firstIndex(of: "#") {
            requirementWithoutFragment = String(rawRequirement[..<fragmentSeparator])
        } else {
            requirementWithoutFragment = rawRequirement
        }

        if finding.host.caseInsensitiveCompare("github.com") == .orderedSame {
            if let repositoryPath = parseGitHubRepositoryPath(requirementWithoutFragment) {
                let normalizedRepositoryPath = repositoryPath.hasSuffix(".git")
                    ? String(repositoryPath.dropLast(4))
                    : repositoryPath
                let prefixes = [
                    "git@github.com:\(normalizedRepositoryPath)",
                    "git@github.com:\(normalizedRepositoryPath).git",
                    "ssh://git@github.com/\(normalizedRepositoryPath)",
                    "ssh://git@github.com/\(normalizedRepositoryPath).git",
                    "git+ssh://git@github.com/\(normalizedRepositoryPath)",
                    "git+ssh://git@github.com/\(normalizedRepositoryPath).git",
                    "github:\(normalizedRepositoryPath)",
                    "github:\(normalizedRepositoryPath).git",
                ]
                return ParsedSourceRepository(
                    host: "github.com",
                    repositoryPath: normalizedRepositoryPath,
                    remoteURL: "git@github.com:\(normalizedRepositoryPath).git",
                    rewritePrefixes: prefixes
                )
            }
        }

        return nil
    }

    private func percentEncodedGitCredentialComponent(_ value: String) -> String {
        var allowed = CharacterSet.urlUserAllowed
        allowed.remove(charactersIn: ":@/?#[]")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func parseGitHubRepositoryPath(_ requirement: String) -> String? {
        if requirement.hasPrefix("github:") {
            let path = String(requirement.dropFirst("github:".count))
            return sanitizedRepositoryPath(path)
        }
        if requirement.hasPrefix("git@github.com:") {
            let path = String(requirement.dropFirst("git@github.com:".count))
            return sanitizedRepositoryPath(path)
        }
        if requirement.hasPrefix("git+ssh://") {
            let stripped = String(requirement.dropFirst("git+ssh://".count))
            return parseGitHubRepositoryPath(stripped)
        }
        if requirement.hasPrefix("ssh://") {
            let stripped = String(requirement.dropFirst("ssh://".count))
            if stripped.hasPrefix("git@github.com/") {
                let path = String(stripped.dropFirst("git@github.com/".count))
                return sanitizedRepositoryPath(path)
            }
            if stripped.hasPrefix("github.com/") {
                let path = String(stripped.dropFirst("github.com/".count))
                return sanitizedRepositoryPath(path)
            }
        }
        return nil
    }

    private func sanitizedRepositoryPath(_ path: String) -> String? {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return nil }
        let components = trimmedPath
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty }
        guard components.count >= 2 else { return nil }
        return components.prefix(2).joined(separator: "/")
    }

    private func availableSSHAgentSocketPath() -> String? {
        guard let socketPath = currentSSHAgentSocketPath() else {
            return nil
        }
        guard FileManager.default.fileExists(atPath: socketPath) else {
            return nil
        }
        return URL(fileURLWithPath: socketPath).standardizedFileURL.path
    }

    private func currentSSHAgentSocketPath() -> String? {
        if let environmentPath = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !environmentPath.isEmpty
        {
            return environmentPath
        }
        do {
            let result = try runProcessSynchronously(
                executablePath: "/bin/launchctl",
                arguments: ["getenv", "SSH_AUTH_SOCK"]
            )
            guard result.exitCode == 0 else {
                return nil
            }
            let launchdPath = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return launchdPath.isEmpty ? nil : launchdPath
        } catch {
            logger.debug("Failed to resolve SSH_AUTH_SOCK from launchd", metadata: [
                "error": .string("\(error)"),
            ])
            return nil
        }
    }

    private func sshAgentCanAuthenticatePrivateRepositories() -> Bool {
        guard let socketPath = availableSSHAgentSocketPath() else {
            return false
        }
        do {
            let result = try runProcessSynchronously(
                executablePath: "/usr/bin/ssh-add",
                arguments: ["-L"],
                environment: ["SSH_AUTH_SOCK": socketPath]
            )
            guard result.exitCode == 0 else {
                return false
            }
            let normalizedOutput = result.stdout.lowercased()
            return !normalizedOutput.isEmpty && !normalizedOutput.contains("the agent has no identities")
        } catch {
            logger.debug("Failed to inspect ssh-agent identities", metadata: [
                "error": .string("\(error)"),
            ])
            return false
        }
    }

    private func looksLikePassphraseProtected(stderr: String) -> Bool {
        let normalized = stderr.lowercased()
        return normalized.contains("passphrase")
            || normalized.contains("incorrect")
            || normalized.contains("private key is encrypted")
    }

    private func inspectSSHPrivateKey(
        at privateKeyURL: URL,
        passphrase: String,
        host: String
    ) throws -> SynchronousProcessResult {
        do {
            return try runProcessSynchronously(
                executablePath: "/usr/bin/ssh-keygen",
                arguments: ["-y", "-P", passphrase, "-f", privateKeyURL.path]
            )
        } catch {
            throw BuildPreparationError("Failed to inspect local source private key", metadata: [
                "host": host,
                "path": privateKeyURL.path,
                "error": "\(error)",
            ])
        }
    }

    private func reencryptSSHPrivateKeyWithoutPassphrase(
        at privateKeyURL: URL,
        oldPassphrase: String,
        host: String
    ) throws -> SynchronousProcessResult {
        do {
            return try runProcessSynchronously(
                executablePath: "/usr/bin/ssh-keygen",
                arguments: ["-p", "-P", oldPassphrase, "-N", "", "-f", privateKeyURL.path]
            )
        } catch {
            throw BuildPreparationError("Failed to decrypt local source private key", metadata: [
                "host": host,
                "path": privateKeyURL.path,
                "error": "\(error)",
            ])
        }
    }

    private struct SynchronousProcessResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    private nonisolated func runProcessSynchronously(
        executablePath: String,
        arguments: [String],
        environment: [String: String] = [:]
    ) throws -> SynchronousProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: stdoutData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return SynchronousProcessResult(
            exitCode: process.terminationStatus,
            stdout: stdout,
            stderr: stderr
        )
    }

    private func writeBuildPreparationScript(
        to root: URL,
        service: ServiceConfig,
        packageManager: String?
    ) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let scriptPath = root.appendingPathComponent("build.sh")
        let installCommand = service.install.map { shellCommand($0) }
        let buildCommand = service.build.map { shellCommand($0) }

        var lines: [String] = []
        lines.append("#!/bin/sh")
        lines.append("set -e")
        lines.append("")
        lines.append("AIB_SCRIPT_STARTED_AT=$(date +%s%3N)")
        lines.append("aib_log() {")
        lines.append("  now=$(date +%s%3N)")
        lines.append("  elapsed_ms=$((now - AIB_SCRIPT_STARTED_AT))")
        lines.append(#"  printf '%s [elapsed_ms=%s] %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")" "$elapsed_ms" "$*""#)
        lines.append("}")
        lines.append("")
        lines.append("ensure_apt_packages() {")
        lines.append("  if ! command -v apt-get >/dev/null 2>&1; then")
        lines.append(#"    aib_log "[aib] apt-get unavailable — cannot install required system packages: $*""#)
        lines.append("    return 1")
        lines.append("  fi")
        lines.append("  apt_started_at=$(date +%s%3N)")
        lines.append("  export DEBIAN_FRONTEND=noninteractive")
        lines.append("  apt-get update -qq >/dev/null 2>&1")
        lines.append("  apt-get install -y -qq \"$@\" >/dev/null 2>&1")
        lines.append("  rm -rf /var/lib/apt/lists/*")
        lines.append("  aib_log \"[aib] apt-get completed for: $* (duration_ms=$(( $(date +%s%3N) - apt_started_at )))\"")
        lines.append("}")
        lines.append("")
        lines.append(#"if [ -n "$AIB_PACKAGE_MANAGER" ]; then"#)
        lines.append("  phase_started_at=$(date +%s%3N)")
        lines.append(#"  aib_log "[aib] Setting up package manager: $AIB_PACKAGE_MANAGER""#)
        lines.append(#"  case "$AIB_PACKAGE_MANAGER" in"#)
        lines.append(#"    pnpm) command -v pnpm >/dev/null 2>&1 || corepack enable pnpm 2>/dev/null || npm install -g pnpm ;;"#)
        lines.append(#"    yarn) command -v yarn >/dev/null 2>&1 || corepack enable yarn 2>/dev/null || npm install -g yarn ;;"#)
        lines.append(#"    bun) command -v bun >/dev/null 2>&1 || npm install -g bun ;;"#)
        lines.append("  esac")
        lines.append(#"  aib_log "[aib] Package manager ready: $AIB_PACKAGE_MANAGER (duration_ms=$(( $(date +%s%3N) - phase_started_at )))""#)
        lines.append("fi")
        lines.append("")
        lines.append("if [ -f /aib-tools/tools.tar.gz ]; then")
        lines.append("  phase_started_at=$(date +%s%3N)")
        lines.append(#"  aib_log "[aib] Extracting cached tools""#)
        lines.append("  tar xzf /aib-tools/tools.tar.gz -C / 2>/dev/null || true")
        lines.append(#"  aib_log "[aib] Cached tools extracted (duration_ms=$(( $(date +%s%3N) - phase_started_at )))""#)
        lines.append("fi")
        lines.append("")
        lines.append("if ! (command -v git >/dev/null 2>&1 && git --version >/dev/null 2>&1); then")
        lines.append(#"  aib_log "[aib] Repairing git toolchain for build""#)
        lines.append("  ensure_apt_packages git")
        lines.append("fi")
        lines.append("")
        lines.append("if [ -f /aib-source-mirrors/.git-rewrites ]; then")
        lines.append("  AIB_LOCAL_SOURCE_MIRRORS_ACTIVE=1")
        lines.append("  phase_started_at=$(date +%s%3N)")
        lines.append(#"  aib_log "[aib] Configuring local source mirrors""#)
        lines.append("  while IFS=\"$(printf '\\t')\" read -r mirror_url prefix; do")
        lines.append("    [ -n \"$mirror_url\" ] || continue")
        lines.append("    [ -n \"$prefix\" ] || continue")
        lines.append("    git config --global --add url.\"$mirror_url\".insteadOf \"$prefix\"")
        lines.append("  done < /aib-source-mirrors/.git-rewrites")
        lines.append("  git config --global --get-regexp '^url\\..*\\.insteadOf$' | sed 's/^/[aib] Source mirror: /' || true")
        lines.append(#"  aib_log "[aib] Local source mirrors configured (duration_ms=$(( $(date +%s%3N) - phase_started_at )))""#)
        lines.append("else")
        lines.append("  AIB_LOCAL_SOURCE_MIRRORS_ACTIVE=0")
        lines.append("fi")
        lines.append("")
        lines.append("if [ -d /aib-auth ] && [ \"$AIB_LOCAL_SOURCE_MIRRORS_ACTIVE\" = \"1\" ]; then")
        lines.append(#"  aib_log "[aib] Source auth bootstrap skipped (local source mirrors active)""#)
        lines.append("fi")
        lines.append("if [ -d /aib-auth ] && [ \"$AIB_LOCAL_SOURCE_MIRRORS_ACTIVE\" != \"1\" ]; then")
        lines.append("  phase_started_at=$(date +%s%3N)")
        lines.append(#"  aib_log "[aib] Configuring explicit source auth for build""#)
        lines.append("  if ! (command -v ssh >/dev/null 2>&1 && ssh -V >/dev/null 2>&1); then")
        lines.append(#"    aib_log "[aib] Repairing OpenSSH client for source auth""#)
        lines.append("    ensure_apt_packages openssh-client git")
        lines.append("  fi")
        lines.append(#"  if [ -n "$AIB_SSH_AUTH_SOCK" ] && [ -S "$AIB_SSH_AUTH_SOCK" ]; then"#)
        lines.append(#"    aib_log "[aib] Forwarding ssh-agent for source auth""#)
        lines.append(#"    export SSH_AUTH_SOCK="$AIB_SSH_AUTH_SOCK""#)
        lines.append("  fi")
        lines.append("  mkdir -p /root/.ssh")
        lines.append("  if [ -f /aib-auth/id_ed25519 ]; then cp /aib-auth/id_ed25519 /root/.ssh/id_ed25519; fi")
        lines.append("  if [ -f /aib-auth/known_hosts ]; then cp /aib-auth/known_hosts /root/.ssh/known_hosts; fi")
        lines.append("  chown root:root /root/.ssh /root/.ssh/id_ed25519 /root/.ssh/known_hosts 2>/dev/null || true")
        lines.append("  chmod 700 /root/.ssh")
        lines.append("  if [ -f /root/.ssh/id_ed25519 ]; then chmod 600 /root/.ssh/id_ed25519; fi")
        lines.append("  if [ -f /root/.ssh/known_hosts ]; then chmod 644 /root/.ssh/known_hosts; fi")
        lines.append("  ls -l /root/.ssh | sed 's/^/[aib] Source auth ls: /'")
        lines.append("  : > /root/.ssh/config")
        lines.append("  {")
        lines.append("    printf '%s\\n' 'Host github.com'")
        lines.append("    printf '%s\\n' '  HostName github.com'")
        lines.append("    printf '%s\\n' '  User git'")
        lines.append("    if [ -f /root/.ssh/id_ed25519 ]; then")
        lines.append("      printf '%s\\n' '  IdentityFile /root/.ssh/id_ed25519'")
        lines.append("      printf '%s\\n' '  IdentitiesOnly yes'")
        lines.append("    fi")
        lines.append("    if [ -n \"$SSH_AUTH_SOCK\" ]; then")
        lines.append("      printf '  IdentityAgent %s\\n' \"$SSH_AUTH_SOCK\"")
        lines.append("    fi")
        lines.append("    printf '%s\\n' '  UserKnownHostsFile /root/.ssh/known_hosts'")
        lines.append("    printf '%s\\n' '  StrictHostKeyChecking yes'")
        lines.append("  } > /root/.ssh/config")
        lines.append("  chmod 600 /root/.ssh/config")
        lines.append(#"  if [ -n "$SSH_AUTH_SOCK" ]; then"#)
        lines.append(#"    export GIT_SSH_COMMAND="ssh -F /root/.ssh/config -o IdentityAgent=$SSH_AUTH_SOCK""#)
        lines.append("  else")
        lines.append(#"    export GIT_SSH_COMMAND="ssh -F /root/.ssh/config""#)
        lines.append("  fi")
        lines.append(#"  git config --global core.sshCommand "$GIT_SSH_COMMAND""#)
        lines.append("  if command -v ssh-keygen >/dev/null 2>&1 && [ -f /root/.ssh/id_ed25519 ]; then ssh-keygen -lf /root/.ssh/id_ed25519 | sed 's/^/[aib] Source auth key: /'; fi")
        lines.append("  if command -v shasum >/dev/null 2>&1; then")
        lines.append("    if [ -f /root/.ssh/id_ed25519 ]; then shasum -a 256 /root/.ssh/id_ed25519 | sed 's/^/[aib] Source auth sha256: /'; fi")
        lines.append("    if [ -f /root/.ssh/known_hosts ]; then shasum -a 256 /root/.ssh/known_hosts | sed 's/^/[aib] Source auth sha256: /'; fi")
        lines.append("  fi")
        lines.append(#"  if [ -n "$SSH_AUTH_SOCK" ] && command -v ssh-add >/dev/null 2>&1; then ssh-add -L 2>/dev/null | sed 's/^/[aib] Source auth agent: /' || true; fi"#)
        lines.append("  if command -v git >/dev/null 2>&1; then")
        lines.append("    if validation_output=\"$(git ls-remote git@github.com:salescore-inc/valuemap-api.git 2>&1)\"; then")
        lines.append("      echo '[aib] Source auth validation: success'")
        lines.append("    else")
        lines.append("      echo '[aib] Source auth validation: failed'")
        lines.append("      printf '%s\\n' \"$validation_output\"")
        lines.append("    fi")
        lines.append("  fi")
        lines.append("  if command -v ssh >/dev/null 2>&1; then")
        lines.append("    if ssh_output=\"$($GIT_SSH_COMMAND -vvT git@github.com </dev/null 2>&1)\"; then")
        lines.append("      printf '%s\\n' \"$ssh_output\"")
        lines.append("    else")
        lines.append("      printf '%s\\n' \"$ssh_output\"")
        lines.append("    fi")
        lines.append("  fi")
        lines.append(#"  aib_log "[aib] Explicit source auth configured (duration_ms=$(( $(date +%s%3N) - phase_started_at )))""#)
        lines.append("fi")
        lines.append("")
        lines.append(#"if [ -n "$AIB_MODULES_DIR" ]; then"#)
        lines.append(#"  aib_log "[aib] Resetting $AIB_MODULES_DIR for linux build output""#)
        lines.append(#"  rm -rf "/app/$AIB_MODULES_DIR""#)
        lines.append("fi")
        lines.append("")
        if let installCommand {
            lines.append("phase_started_at=$(date +%s%3N)")
            lines.append(#"aib_log "[aib] Installing dependencies: \#(installCommand)""#)
            lines.append(installCommand)
            lines.append(#"aib_log "[aib] Install phase completed (duration_ms=$(( $(date +%s%3N) - phase_started_at )))""#)
            lines.append("")
        }
        if let buildCommand {
            lines.append("phase_started_at=$(date +%s%3N)")
            lines.append(#"aib_log "[aib] Building: \#(buildCommand)""#)
            lines.append(buildCommand)
            lines.append(#"aib_log "[aib] Build phase completed (duration_ms=$(( $(date +%s%3N) - phase_started_at )))""#)
            lines.append("")
        }
        switch packageManager {
        case "pnpm":
            lines.append("phase_started_at=$(date +%s%3N)")
            lines.append(#"aib_log "[aib] Pruning runtime dependencies: pnpm prune --prod""#)
            lines.append("pnpm prune --prod")
            lines.append(#"aib_log "[aib] Runtime dependency prune completed (duration_ms=$(( $(date +%s%3N) - phase_started_at )))""#)
            lines.append("")
        case "npm":
            lines.append("phase_started_at=$(date +%s%3N)")
            lines.append(#"aib_log "[aib] Pruning runtime dependencies: npm prune --omit=dev""#)
            lines.append("npm prune --omit=dev")
            lines.append(#"aib_log "[aib] Runtime dependency prune completed (duration_ms=$(( $(date +%s%3N) - phase_started_at )))""#)
            lines.append("")
        default:
            break
        }
        if installCommand == nil, buildCommand == nil {
            if let packageManager {
                lines.append(#"aib_log "[aib] No explicit install/build commands configured for \#(packageManager) service""#)
            } else {
                lines.append(#"aib_log "[aib] No explicit install/build commands configured""#)
            }
        }
        try lines.joined(separator: "\n").appending("\n").write(to: scriptPath, atomically: true, encoding: .utf8)
        return root
    }

    private func cleanupBuildArtifacts(scriptDir: URL, authRoot: URL) {
        if FileManager.default.fileExists(atPath: scriptDir.path) {
            do {
                try FileManager.default.removeItem(at: scriptDir)
            } catch {
                logger.debug("Failed to clean build scripts", metadata: [
                    "path": .string(scriptDir.path),
                    "error": .string("\(error)"),
                ])
            }
        }
        if FileManager.default.fileExists(atPath: authRoot.path) {
            do {
                try FileManager.default.removeItem(at: authRoot)
            } catch {
                logger.debug("Failed to clean build auth", metadata: [
                    "path": .string(authRoot.path),
                    "error": .string("\(error)"),
                ])
            }
        }
    }

    private struct PreparedWorkspaceCacheManifest: Codable {
        let version: String
        let fingerprint: String
    }

    private func shellQuote(_ arg: String) -> String {
        if arg.isEmpty { return "''" }
        let safe = arg.allSatisfy { character in
            character.isLetter || character.isNumber || character == "/" || character == "." || character == "-" || character == "_" || character == "=" || character == ":"
        }
        if safe { return arg }
        return "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func shellCommand(_ argv: [String]) -> String {
        argv.map { shellQuote($0) }.joined(separator: " ")
    }

    private func sanitizedServiceID(_ value: String) -> String {
        value.replacingOccurrences(of: "/", with: "__")
    }

    private func stagedRuntimeSkillMounts(
        serviceID: String,
        configBaseDirectory: String
    ) -> [(source: String, destination: String)] {
        let serviceRoot = URL(fileURLWithPath: configBaseDirectory)
            .appendingPathComponent("generated/runtime/skills/\(sanitizedServiceID(serviceID))")
            .standardizedFileURL

        return [
            (source: serviceRoot.appendingPathComponent(".claude").path, destination: "/app/.claude"),
            (source: serviceRoot.appendingPathComponent(".agents").path, destination: "/app/.agents"),
            (source: serviceRoot.appendingPathComponent("skills").path, destination: "/app/skills"),
        ].filter { mount in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: mount.source, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }
}

// MARK: - URLSession Download Delegate

/// Reports kernel download progress to a Foundation `Progress` object and logs milestones.
private final class KernelDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let progress: Progress
    private let logger: Logger
    private var lastLoggedPercent: Int = -1

    init(progress: Progress, logger: Logger) {
        self.progress = progress
        self.logger = logger
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        if progress.totalUnitCount == 0, totalBytesExpectedToWrite > 0 {
            progress.totalUnitCount = totalBytesExpectedToWrite
        }
        progress.completedUnitCount = totalBytesWritten

        // Log every 10% for CLI visibility
        if totalBytesExpectedToWrite > 0 {
            let percent = Int(totalBytesWritten * 100 / totalBytesExpectedToWrite)
            let bucket = percent / 10 * 10
            if bucket > lastLoggedPercent {
                lastLoggedPercent = bucket
                let downloadedMB = totalBytesWritten / (1024 * 1024)
                let totalMB = totalBytesExpectedToWrite / (1024 * 1024)
                logger.info("Downloading kernel: \(bucket)% (\(downloadedMB)/\(totalMB) MB)")
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // URLSession deletes the file after this delegate method returns.
        // The async download(from:) call receives this URL, so we don't need to copy here.
    }
}

// MARK: - Container Log Writer

/// Bridges container stdout/stderr to the structured logger.
private final class LogWriter: Writer, @unchecked Sendable {
    private let logger: Logger
    private let containerID: String
    private let stream: String
    private let containerState: ContainerState?
    private let pendingLine = Mutex("")

    init(logger: Logger, containerID: String, stream: String, containerState: ContainerState? = nil) {
        self.logger = logger
        self.containerID = containerID
        self.stream = stream
        self.containerState = containerState
    }

    func write(_ data: Data) throws {
        guard !data.isEmpty else { return }
        let chunk = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .ascii)
            ?? "<binary \(data.count) bytes>"

        let lines = pendingLine.withLock { buffer in
            buffer.append(chunk)
            var completed: [String] = []
            while let range = buffer.rangeOfCharacter(from: .newlines) {
                let line = String(buffer[..<range.lowerBound])
                completed.append(line)
                buffer = String(buffer[range.upperBound...])
            }
            return completed
        }

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .newlines)
            guard !line.isEmpty else { continue }
            if line == EntrypointGenerator.runPhaseStartedMarker {
                containerState?.runPhaseStarted.withLock { $0 = true }
                logger.debug("Container entered run phase", metadata: [
                    "container_id": .string(containerID),
                ])
                continue
            }
            logger.info("\(line)", metadata: [
                "container_id": .string(containerID),
                "stream": .string(stream),
            ])
        }
    }

    func close() throws {
        let tail = pendingLine.withLock { buffer in
            defer { buffer = "" }
            return buffer
        }.trimmingCharacters(in: .newlines)

        guard !tail.isEmpty else { return }
        logger.info("\(tail)", metadata: [
            "container_id": .string(containerID),
            "stream": .string(stream),
        ])
    }
}

private final class BufferWriter: Writer, @unchecked Sendable {
    private let buffer = Mutex(Data())

    var text: String {
        let data = buffer.withLock { $0 }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? String(data: data, encoding: .ascii)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
    }

    func write(_ data: Data) throws {
        guard !data.isEmpty else { return }
        buffer.withLock { $0.append(data) }
    }

    func close() throws {}
}
