import AIBConfig
import AIBRuntimeCore
import Containerization
import ContainerizationExtras
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
    private let logger: Logger

    /// Observable progress for one-time setup tasks (kernel download).
    /// Thread-safe (`Progress` is `Sendable`) so the App can observe from `@MainActor`
    /// while the actor updates it during download.
    public nonisolated let setupProgress: Progress

    /// Shared container manager (lazy-initialized on first spawn).
    private var manager: ContainerManager?

    /// Active containers keyed by container ID for lifecycle management.
    private var containers: [String: LinuxContainer] = [:]

    /// Directory for host-side Unix domain sockets and generated entrypoint scripts.
    private let socketDir: URL

    /// Cache directory for kernel, init image, and OCI image store.
    private let cacheRoot: URL

    public init(logger: Logger) {
        self.logger = logger
        self.setupProgress = Progress(totalUnitCount: 0)
        self.cacheRoot = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".aib/container-cache")
        self.socketDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aib-sockets")
    }

    // MARK: - ProcessController

    public func spawn(
        service: ServiceConfig,
        resolvedPort: Int,
        gatewayPort: Int,
        configBaseDirectory: String
    ) async throws -> ChildHandle {
        // Ensure the container manager is initialized (kernel + initfs + image store)
        try await ensureManager()

        let sanitizedID = service.id.rawValue.replacingOccurrences(of: "/", with: "-")
        let containerID = "aib-\(sanitizedID)-\(UUID().uuidString.prefix(8).lowercased())"

        let cwd = service.cwd.map { path in
            URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: configBaseDirectory))
                .standardizedFileURL.path
        } ?? configBaseDirectory

        // Detect runtime and package manager for entrypoint generation
        let runtime = EntrypointGenerator.detectRuntime(service: service)
        let packageManager = EntrypointGenerator.detectPackageManager(service: service)

        // Determine OCI image reference
        let imageRef = try imageReference(for: service, runtime: runtime, packageManager: packageManager)

        // Generate entrypoint and bridge scripts (mounted via VirtioFS)
        let scripts = try EntrypointGenerator.generate(
            service: service,
            runtime: runtime,
            baseDir: socketDir,
            containerID: containerID
        )

        let envArray = buildEnvironment(
            service: service,
            resolvedPort: resolvedPort,
            gatewayPort: gatewayPort,
            sanitizedID: sanitizedID,
            configBaseDirectory: configBaseDirectory,
            runtime: runtime,
            packageManager: packageManager,
            bridgeCommand: scripts.bridgeCommand
        )

        // Set up host-side Unix domain socket for vsock relay
        try FileManager.default.createDirectory(at: socketDir, withIntermediateDirectories: true)
        let hostSocketPath = socketDir.appendingPathComponent("\(containerID).sock")
        // Clean up any stale socket file from a previous run
        try? FileManager.default.removeItem(at: hostSocketPath)

        logger.info("Creating container", metadata: [
            "service_id": .string(service.id.rawValue),
            "container_id": .string(containerID),
            "image": .string(imageRef),
            "socket": .string(hostSocketPath.path),
        ])

        // Create container via ContainerManager
        guard var mgr = self.manager else {
            throw ProcessSpawnError("Container manager not initialized", metadata: [:])
        }

        let runtimeDir = URL(fileURLWithPath: configBaseDirectory)
            .appendingPathComponent("generated/runtime")
            .standardizedFileURL.path
        let runtimeDirExists = FileManager.default.fileExists(atPath: runtimeDir)

        // Log writers to capture container stdout/stderr
        let stdoutWriter = LogWriter(logger: logger, containerID: containerID, stream: "stdout")
        let stderrWriter = LogWriter(logger: logger, containerID: containerID, stream: "stderr")

        logger.info("Container entrypoint", metadata: [
            "container_id": .string(containerID),
            "runtime": .string(runtime.rawValue),
            "scripts": .string(scripts.directory.path),
        ])

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

            // Network: VmnetNetwork (configured at ContainerManager level) provides
            // outbound internet for the guest (apt, pip, npm). Host-to-guest inbound
            // traffic uses UnixSocketRelay via vsock (vmnet IPs are NAT'd/not routable).

            // Socket relay: expose guest UDS to host via vsock.
            // Guest service listens on TCP :PORT → bridge script → /tmp/aib-svc.sock
            // → vsock relay → host UDS at socketDir/{containerID}.sock
            config.sockets = [
                UnixSocketConfiguration(
                    source: URL(filePath: "/tmp/aib-svc.sock"),
                    destination: hostSocketPath,
                    direction: .outOf
                ),
            ]

            // Mount source directory via VirtioFS
            config.mounts.append(.share(source: cwd, destination: "/app"))

            // Mount generated scripts (entrypoint + bridge) via VirtioFS
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
        }
        self.manager = mgr

        if let containerAddress = container.interfaces.first?.ipv4Address.address.description {
            logger.info("Container network configured", metadata: [
                "container_id": .string(containerID),
                "ip": .string(containerAddress),
            ])
        }

        // Start the container VM
        try await container.create()
        try await container.start()

        // Track container for lifecycle management
        containers[containerID] = container

        // Set up state tracking
        let state = ContainerState()

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
            containerState: state,
            startedAt: Date(),
            resolvedPort: resolvedPort,
            unixSocketPath: hostSocketPath.path,
            scriptDir: scripts.directory,
            monitorTask: monitorTask,
            logTask: nil
        )
    }

    public func terminateGroup(_ handle: ChildHandle, grace: Duration) async -> TerminationResult {
        guard let container = containers[handle.containerID] else {
            return TerminationResult(terminatedGracefully: false, exitCode: nil)
        }
        do {
            try await container.stop()
            handle.containerState.isAlive.withLock { $0 = false }
            handle.monitorTask?.cancel()
            containers.removeValue(forKey: handle.containerID)
            cleanupSocket(handle)
            cleanupManager(id: handle.containerID)
            return TerminationResult(terminatedGracefully: true, exitCode: 0)
        } catch {
            logger.warning("Container graceful stop failed", metadata: [
                "container_id": .string(handle.containerID),
                "error": .string("\(error)"),
            ])
            handle.monitorTask?.cancel()
            containers.removeValue(forKey: handle.containerID)
            cleanupSocket(handle)
            cleanupManager(id: handle.containerID)
            return TerminationResult(terminatedGracefully: false, exitCode: nil)
        }
    }

    public func killGroup(_ handle: ChildHandle) async {
        guard let container = containers[handle.containerID] else { return }
        do {
            try await container.kill(SIGKILL)
        } catch {
            // Best-effort — VM may already be dead
        }
        handle.containerState.isAlive.withLock { $0 = false }
        handle.monitorTask?.cancel()
        containers.removeValue(forKey: handle.containerID)
        cleanupSocket(handle)
        cleanupManager(id: handle.containerID)
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

    /// Remove the host-side Unix domain socket and generated scripts.
    private func cleanupSocket(_ handle: ChildHandle) {
        if let socketPath = handle.unixSocketPath {
            try? FileManager.default.removeItem(atPath: socketPath)
        }
        if let scriptDir = handle.scriptDir {
            EntrypointGenerator.cleanup(directory: scriptDir)
        }
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
        sanitizedID: String,
        configBaseDirectory: String,
        runtime: EntrypointGenerator.Runtime,
        packageManager: String?,
        bridgeCommand: String
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

        // Entrypoint script environment (consumed by /aib-scripts/entrypoint.sh)
        if let pm = packageManager {
            env["AIB_PACKAGE_MANAGER"] = pm
        }
        // Directory containing platform-specific binaries that must be isolated
        // between the macOS host and Linux guest (e.g. node_modules).
        if let modulesDir = EntrypointGenerator.platformModulesDir(runtime: runtime) {
            env["AIB_MODULES_DIR"] = modulesDir
        }
        if let install = service.install, !install.isEmpty {
            env["AIB_INSTALL_COMMAND"] = install.joined(separator: " ")
        }
        if let build = service.build, !build.isEmpty {
            env["AIB_BUILD_COMMAND"] = build.joined(separator: " ")
        }
        env["AIB_RUN_COMMAND"] = service.run.joined(separator: " ")
        env["AIB_BRIDGE_COMMAND"] = bridgeCommand

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
            let normalizedID = sanitizedID.replacingOccurrences(of: "-", with: "__")
            let mcpConfigDir = "/tmp/claude-config/\(normalizedID)"
            let mcpConfigSource = "/aib-runtime/mcp/\(normalizedID)"
            env["CLAUDE_CONFIG_DIR"] = mcpConfigDir
            env["AIB_CLAUDE_CONFIG_SOURCE"] = mcpConfigSource
            env["ENABLE_CLAUDEAI_MCP_SERVERS"] = "false"
        }

        // Force line-buffered stdout for Python
        env["PYTHONUNBUFFERED"] = "1"

        // Service-specific env vars (highest priority — override defaults)
        for (key, value) in service.env {
            env[key] = value
        }

        return env.map { "\($0.key)=\($0.value)" }
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

    init(logger: Logger, containerID: String, stream: String) {
        self.logger = logger
        self.containerID = containerID
        self.stream = stream
    }

    func write(_ data: Data) throws {
        guard !data.isEmpty else { return }
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .ascii)
            ?? "<binary \(data.count) bytes>"
        // Split on newlines and log each line separately
        for line in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            logger.info("\(line)", metadata: [
                "container_id": .string(containerID),
                "stream": .string(stream),
            ])
        }
    }

    func close() throws {}
}
