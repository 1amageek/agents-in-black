import AIBConfig
import AIBRuntimeCore
import Foundation
import YAML

public struct ResolvedConfig: Sendable {
    public var config: AIBConfig
    public var warnings: [String]
    /// Per-service deploy metadata keyed by namespaced service ID (e.g., "agent/node").
    /// Populated during config resolution from runtime detection results.
    public var serviceMetadata: [String: ServiceDeployMetadata]
    public var sourceAuthRequirements: [WorkspaceSourceAuthRequirement]

    public init(
        config: AIBConfig,
        warnings: [String],
        serviceMetadata: [String: ServiceDeployMetadata] = [:],
        sourceAuthRequirements: [WorkspaceSourceAuthRequirement] = []
    ) {
        self.config = config
        self.warnings = warnings
        self.serviceMetadata = serviceMetadata
        self.sourceAuthRequirements = sourceAuthRequirements
    }
}

public enum WorkspaceSyncer {
    /// Flatten workspace repos into a validated AIBConfig.
    /// This is the primary entry point for resolving workspace.yaml into runtime config.
    public static func resolveConfig(workspaceRoot: String, workspace: AIBWorkspaceConfig) throws -> ResolvedConfig {
        var services: [ServiceConfig] = []
        var warnings: [String] = []
        var serviceMetadata: [String: ServiceDeployMetadata] = [:]

        for repo in workspace.repos where repo.enabled {
            let repoRoot = URL(fileURLWithPath: repo.path, relativeTo: URL(fileURLWithPath: workspaceRoot)).standardizedFileURL.path
            let repoURL = URL(fileURLWithPath: repoRoot)
            let allDetections = RuntimeAdapterRegistry.detectAll(repoURL: repoURL)
            let detectionsByRuntime = Dictionary(uniqueKeysWithValues: allDetections.map { ($0.runtime, $0) })

            if let inlineServices = repo.services {
                // Explicit services list (may be empty if all were removed)
                if !inlineServices.isEmpty {
                    let workspaceSkills = workspace.skills ?? []
                    let converted = try inlineServices.map { try convertInlineService($0, repo: repo, repoRoot: repoRoot, workspaceSkills: workspaceSkills) }
                    let namespaced = namespacedServices(from: converted, repo: repo, repoRoot: repoRoot)
                    services.append(contentsOf: namespaced)

                    // Build metadata for each inline service
                    for (idx, inline) in inlineServices.enumerated() {
                        let namespacedID = namespaced[idx].id.rawValue
                        let meta = resolveServiceMetadata(
                            inline: inline,
                            repo: repo,
                            workspaceRoot: workspaceRoot,
                            detectionsByRuntime: detectionsByRuntime
                        )
                        serviceMetadata[namespacedID] = meta
                    }
                }
            } else {
                switch repo.status {
                case .discoverable:
                    let generated = generateDiscoverableServices(repo: repo, repoRoot: repoRoot)
                    if generated.isEmpty {
                        warnings.append("repo \(repo.name): discoverable but no selected command")
                    } else {
                        services.append(contentsOf: generated)

                        // Build metadata for discoverable services
                        for service in generated {
                            let serviceID = service.id.rawValue
                            let runtime = RuntimeKind.fromCommand(service.run.first ?? "")
                            let detection = detectionsByRuntime[runtime] ?? allDetections.first
                            let packageName = resolvePackageName(
                                runtime: runtime,
                                detection: detection,
                                runCommand: service.run,
                                fallback: serviceID.split(separator: "/").last.map(String.init) ?? serviceID
                            )
                            let dockerfilePath = findDockerfilePath(
                                repoPath: repo.path,
                                runtime: runtime,
                                workspaceRoot: workspaceRoot
                            )
                            serviceMetadata[serviceID] = ServiceDeployMetadata(
                                runtime: detection?.runtime ?? runtime,
                                packageManager: detection?.packageManager ?? .unknown,
                                packageName: packageName,
                                repoPath: repo.path,
                                dockerfilePath: dockerfilePath,
                                executionRootPath: URL(fileURLWithPath: repo.path, relativeTo: URL(fileURLWithPath: workspaceRoot))
                                    .standardizedFileURL
                                    .path(percentEncoded: false)
                            )
                        }
                    }
                case .unresolved:
                    warnings.append("repo \(repo.name): unresolved (skipped)")
                case .ignored:
                    continue
                }
            }
        }

        let gateway = GatewayConfig(port: workspace.gateway.port)
        let config = AIBConfig(version: 1, gateway: gateway, services: services, logLevel: "info")
        let validation = try AIBConfigValidator.validate(config)
        if !validation.errors.isEmpty {
            throw ValidationError("Generated services config invalid", metadata: ["errors": validation.errors.joined(separator: " | ")])
        }
        warnings.append(contentsOf: validation.warnings)

        let sourceAuthAnalysis = analyzeSourceAuthRequirements(
            services: services,
            serviceMetadata: serviceMetadata,
            workspaceRoot: workspaceRoot
        )
        warnings.append(contentsOf: sourceAuthAnalysis.warnings)

        return ResolvedConfig(
            config: config,
            warnings: warnings,
            serviceMetadata: serviceMetadata,
            sourceAuthRequirements: sourceAuthAnalysis.requirements
        )
    }

    /// Sync workspace: resolve config and write runtime connection artifacts.
    /// Does NOT write a separate runtime manifest — workspace.yaml is the sole source of truth.
    public static func sync(workspaceRoot: String, workspace: AIBWorkspaceConfig) throws -> WorkspaceSyncResult {
        let resolved = try resolveConfig(workspaceRoot: workspaceRoot, workspace: workspace)
        try writeRuntimeConnectionArtifacts(
            config: resolved.config,
            workspaceRoot: workspaceRoot,
            gatewayPort: workspace.gateway.port
        )
        try writeRuntimeClaudeCodePlugins(
            resolved: resolved,
            workspaceRoot: workspaceRoot,
            workspace: workspace
        )
        return WorkspaceSyncResult(
            serviceCount: resolved.config.services.count,
            warnings: resolved.warnings,
            sourceAuthRequirements: resolved.sourceAuthRequirements
        )
    }

    /// Write runtime connection JSON artifacts for agent services.
    public static func writeRuntimeConnectionArtifacts(
        config: AIBConfig,
        workspaceRoot: String,
        gatewayPort: Int
    ) throws {
        let outputRoot = URL(fileURLWithPath: ".aib/generated/runtime/connections", relativeTo: URL(fileURLWithPath: workspaceRoot))
            .standardizedFileURL

        do {
            try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        } catch {
            throw ConfigError(
                "Failed to create runtime connection output directory",
                metadata: ["path": outputRoot.path, "underlying_error": "\(error)"]
            )
        }

        let servicesByID = Dictionary(uniqueKeysWithValues: config.services.map { ($0.id, $0) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        for service in config.services where service.kind == .agent {
            let mcpTargets = resolveConnectionTargets(
                service.connections.mcpServers,
                servicesByID: servicesByID,
                gatewayPort: gatewayPort,
                defaultPathProvider: { target in target.mcp?.path ?? "/mcp" }
            )
            let a2aTargets = resolveConnectionTargets(
                service.connections.a2aAgents,
                servicesByID: servicesByID,
                gatewayPort: gatewayPort,
                defaultPathProvider: { target in target.a2a?.rpcPath ?? "/a2a" }
            )

            let artifact = RuntimeConnectionArtifact(
                serviceID: service.id.rawValue,
                mcpServers: mcpTargets,
                a2aAgents: a2aTargets
            )

            let filename = sanitizedServiceFilename(service.id.rawValue) + ".json"
            let outputURL = outputRoot.appendingPathComponent(filename)
            do {
                let data = try encoder.encode(artifact)
                try data.write(to: outputURL, options: .atomic)
            } catch {
                throw ConfigError(
                    "Failed to write runtime connection artifact",
                    metadata: ["path": outputURL.path, "underlying_error": "\(error)"]
                )
            }

        }
    }

    /// Write per-agent Claude Code plugin bundles for local runtime.
    /// Bundles are staged under `.aib/generated/runtime/plugins/{service-id}/`.
    public static func writeRuntimeClaudeCodePlugins(
        resolved: ResolvedConfig,
        workspaceRoot: String,
        workspace: AIBWorkspaceConfig
    ) throws {
        let runtimeRoot = URL(fileURLWithPath: ".aib/generated/runtime", relativeTo: URL(fileURLWithPath: workspaceRoot))
            .standardizedFileURL
        let outputRoot = runtimeRoot.appendingPathComponent("plugins", isDirectory: true)
            .standardizedFileURL

        if FileManager.default.fileExists(atPath: outputRoot.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: outputRoot)
        }
        try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)

        for legacyDirectory in ["mcp", "skills"] {
            let legacyURL = runtimeRoot.appendingPathComponent(legacyDirectory, isDirectory: true)
            if FileManager.default.fileExists(atPath: legacyURL.path(percentEncoded: false)) {
                try FileManager.default.removeItem(at: legacyURL)
            }
        }

        let workspaceSkillsByID = Dictionary(uniqueKeysWithValues: (workspace.skills ?? []).map { ($0.id, $0) })
        let servicesByID = Dictionary(uniqueKeysWithValues: resolved.config.services.map { ($0.id, $0) })
        let skillIDsByService = workspace.repos
            .filter(\.enabled)
            .reduce(into: [String: [String]]()) { partial, repo in
                guard let services = repo.services else { return }
                for service in services {
                    partial["\(repo.namespace)/\(service.id)"] = service.skills ?? []
                }
            }

        for resolvedService in resolved.config.services where resolvedService.kind == .agent {
            let namespacedID = resolvedService.id.rawValue
            let assignedSkillIDs = skillIDsByService[namespacedID] ?? []
            let executionRootPath = resolved.serviceMetadata[namespacedID]?.executionRootPath
                ?? resolvedService.cwd
                ?? workspaceRoot

            let mcpTargets = resolveConnectionTargets(
                resolvedService.connections.mcpServers,
                servicesByID: servicesByID,
                gatewayPort: resolved.config.gateway.port,
                defaultPathProvider: { target in target.mcp?.path ?? "/mcp" }
            )

            let template = ClaudeCodePluginTemplate(
                serviceID: namespacedID,
                servers: mcpTargets.map { target in
                    .init(
                        name: ClaudeCodePluginBundle.mcpServerName(
                            serviceRef: target.serviceRef,
                            resolvedURL: target.resolvedURL
                        ),
                        serviceRef: target.serviceRef,
                        source: target.source
                    )
                }
            )
            let binding = ClaudeCodePluginBinding(
                serviceID: namespacedID,
                servers: mcpTargets.map { target in
                    .init(
                        name: ClaudeCodePluginBundle.mcpServerName(
                            serviceRef: target.serviceRef,
                            resolvedURL: target.resolvedURL
                        ),
                        resolvedURL: target.resolvedURL
                    )
                }
            )

            try writeRuntimeClaudeCodePlugin(
                serviceID: namespacedID,
                assignedSkillIDs: assignedSkillIDs,
                workspaceSkillsByID: workspaceSkillsByID,
                workspaceRoot: workspaceRoot,
                executionRootPath: executionRootPath,
                outputRoot: outputRoot,
                template: template,
                binding: binding
            )
        }
    }

    private static func namespacedServices(from repoServices: [ServiceConfig], repo: WorkspaceRepo, repoRoot: String) -> [ServiceConfig] {
        repoServices.map { service in
            var updated = service
            updated.id = ServiceID("\(repo.namespace)/\(service.id.rawValue)")
            if let cwd = service.cwd {
                updated.cwd = URL(fileURLWithPath: cwd, relativeTo: URL(fileURLWithPath: repoRoot)).standardizedFileURL.path
            } else {
                updated.cwd = repoRoot
            }
            updated.restartAffects = service.restartAffects.map { ServiceID("\(repo.namespace)/\($0.rawValue)") }
            updated.connections = namespacedConnections(service.connections, repoNamespace: repo.namespace)
            return updated
        }
    }

    private static func namespacedConnections(_ connections: ServiceConnectionsConfig, repoNamespace: String) -> ServiceConnectionsConfig {
        ServiceConnectionsConfig(
            mcpServers: connections.mcpServers.map { namespacedConnectionTarget($0, repoNamespace: repoNamespace) },
            a2aAgents: connections.a2aAgents.map { namespacedConnectionTarget($0, repoNamespace: repoNamespace) }
        )
    }

    private static func namespacedConnectionTarget(_ target: ServiceConnectionTarget, repoNamespace: String) -> ServiceConnectionTarget {
        guard let serviceRef = target.serviceRef, !serviceRef.isEmpty else {
            return target
        }
        if serviceRef.contains("/") {
            return target
        }
        return ServiceConnectionTarget(serviceRef: "\(repoNamespace)/\(serviceRef)", url: target.url)
    }

    private static func generateDiscoverableServices(repo: WorkspaceRepo, repoRoot: String) -> [ServiceConfig] {
        let repoURL = URL(fileURLWithPath: repoRoot)
        let allDetections = RuntimeAdapterRegistry.detectAll(repoURL: repoURL)

        if allDetections.count <= 1 {
            // Single runtime: use selectedCommand with "main" ID (original behavior)
            guard let selected = repo.selectedCommand, !selected.isEmpty else { return [] }
            let defaults = RuntimeAdapterRegistry.defaults(for: repo.runtime, packageManager: repo.packageManager)
            let detectedKind = allDetections.first?.suggestedServiceKind
            let resolvedKind = (detectedKind != nil && detectedKind != .unknown) ? detectedKind! : defaults.serviceKind
            return [ServiceConfig(
                id: ServiceID("\(repo.namespace)/main"),
                kind: resolvedKind,
                mountPath: "/\(repo.namespace)",
                port: 0,
                cwd: repoRoot,
                run: selected,
                build: defaults.buildCommand,
                install: defaults.installCommand,
                watchMode: defaults.watchMode,
                watchPaths: defaults.watchPaths,
                restartAffects: [],
                pathRewrite: .stripPrefix,
                cookiePathRewrite: true,
                env: [:],
                health: .init(),
                restart: .init(),
                concurrency: .init(),
                auth: .init()
            )]
        }

        // Multiple runtimes: generate a service per runtime
        var services: [ServiceConfig] = []
        for detection in allDetections {
            guard let command = detection.candidates.first?.argv, !command.isEmpty else { continue }
            let defaults = RuntimeAdapterRegistry.defaults(for: detection.runtime, packageManager: detection.packageManager)
            let resolvedKind = detection.suggestedServiceKind != .unknown ? detection.suggestedServiceKind : defaults.serviceKind
            let localID = detection.runtime.rawValue
            services.append(ServiceConfig(
                id: ServiceID("\(repo.namespace)/\(localID)"),
                kind: resolvedKind,
                mountPath: "/\(repo.namespace)/\(localID)",
                port: 0,
                cwd: repoRoot,
                run: command,
                build: defaults.buildCommand,
                install: defaults.installCommand,
                watchMode: defaults.watchMode,
                watchPaths: defaults.watchPaths,
                restartAffects: [],
                pathRewrite: .stripPrefix,
                cookiePathRewrite: true,
                env: [:],
                health: .init(),
                restart: .init(),
                concurrency: .init(),
                auth: .init()
            ))
        }
        return services
    }

    private static func convertInlineService(_ inline: WorkspaceRepoServiceConfig, repo: WorkspaceRepo, repoRoot: String, workspaceSkills: [WorkspaceSkillConfig] = []) throws -> ServiceConfig {
        let watchMode = WatchMode(rawValue: inline.watchMode ?? "external") ?? .external
        let pathRewrite = PathRewriteMode(rawValue: inline.pathRewrite ?? "strip_prefix") ?? .stripPrefix
        let overflowMode = OverflowMode(rawValue: inline.concurrency?.overflowMode ?? "reject") ?? .reject
        let authMode = AuthMode(rawValue: inline.auth?.mode ?? "off") ?? .off
        let resolvedKind = inline.kind.flatMap(ServiceKind.init(rawValue:))
            ?? inferServiceKind(from: inline.mountPath)

        let mcpServers = (inline.connections?.mcpServers ?? []).map { ServiceConnectionTarget(serviceRef: $0.serviceRef, url: $0.url) }

        let connectionConfig = ServiceConnectionsConfig(
            mcpServers: mcpServers,
            a2aAgents: (inline.connections?.a2aAgents ?? []).map { ServiceConnectionTarget(serviceRef: $0.serviceRef, url: $0.url) }
        )
        let mcpConfig: MCPServiceConfig?
        if let mcp = inline.mcp {
            let transport = MCPTransport(rawValue: mcp.transport ?? "streamable_http") ?? .streamableHTTP
            mcpConfig = MCPServiceConfig(transport: transport, path: mcp.path ?? "/mcp")
        } else {
            mcpConfig = nil
        }
        let a2aConfig = inline.a2a.map { A2AServiceConfig(cardPath: $0.cardPath ?? "/.well-known/agent.json", rpcPath: $0.rpcPath ?? "/a2a") }

        return ServiceConfig(
            id: ServiceID(inline.id),
            kind: resolvedKind,
            mountPath: inline.mountPath,
            port: inline.port ?? 0,
            cwd: inline.cwd,
            run: inline.run,
            build: inline.build,
            install: inline.install,
            watchMode: watchMode,
            watchPaths: inline.watchPaths ?? [],
            restartAffects: (inline.restartAffects ?? []).map { ServiceID($0) },
            pathRewrite: pathRewrite,
            cookiePathRewrite: inline.cookiePathRewrite ?? true,
            env: Self.mergeModelEnv(base: inline.env ?? [:], model: inline.model, kind: resolvedKind),
            health: .init(
                livenessPath: inline.health?.livenessPath ?? "/health/live",
                readinessPath: inline.health?.readinessPath ?? "/health/ready",
                startupReadyTimeout: .init(inline.health?.startupReadyTimeout ?? "30s"),
                checkInterval: .init(inline.health?.checkInterval ?? "2s"),
                failureThreshold: inline.health?.failureThreshold ?? 3
            ),
            restart: .init(
                drainTimeout: .init(inline.restart?.drainTimeout ?? "10s"),
                shutdownGracePeriod: .init(inline.restart?.shutdownGracePeriod ?? "10s"),
                backoffInitial: .init(inline.restart?.backoffInitial ?? "1s"),
                backoffMax: .init(inline.restart?.backoffMax ?? "30s")
            ),
            concurrency: .init(
                maxInflight: inline.concurrency?.maxInflight ?? 80,
                overflowMode: overflowMode,
                queueTimeout: inline.concurrency?.queueTimeout.map { DurationString($0) }
            ),
            auth: .init(mode: authMode),
            connections: connectionConfig,
            mcp: mcpConfig,
            a2a: a2aConfig
        )
    }

    /// Default LLM model for agent services when none is explicitly configured.
    static let defaultAgentModel = "claude-sonnet-4-6"

    /// Merge the dedicated `model` field into the env dict as `MODEL`.
    /// Uses `defaultAgentModel` when no model is specified for agent services.
    /// Explicit env["MODEL"] takes precedence.
    private static func mergeModelEnv(base: [String: String], model: String?, kind: ServiceKind) -> [String: String] {
        var env = base
        guard env["MODEL"] == nil else { return env }
        if let model, !model.isEmpty {
            env["MODEL"] = model
        } else if kind == .agent {
            env["MODEL"] = defaultAgentModel
        }
        return env
    }

    private static func inferServiceKind(from mountPath: String) -> ServiceKind {
        if mountPath.hasPrefix("/agents/") {
            return .agent
        }
        if mountPath.hasPrefix("/mcp/") {
            return .mcp
        }
        return .unknown
    }

    private static func resolveConnectionTargets(
        _ targets: [ServiceConnectionTarget],
        servicesByID: [ServiceID: ServiceConfig],
        gatewayPort: Int,
        defaultPathProvider: (ServiceConfig) -> String
    ) -> [ResolvedConnectionTarget] {
        targets.compactMap { target in
            if let url = target.url, !url.isEmpty {
                return ResolvedConnectionTarget(
                    serviceRef: nil,
                    resolvedURL: url,
                    source: "url"
                )
            }
            guard let serviceRef = target.serviceRef, !serviceRef.isEmpty else {
                return nil
            }
            guard let resolvedService = servicesByID[ServiceID(serviceRef)] else {
                return nil
            }
            let base = "http://localhost:\(gatewayPort)\(resolvedService.mountPath)"
            let suffix = normalizedPath(defaultPathProvider(resolvedService))
            return ResolvedConnectionTarget(
                serviceRef: serviceRef,
                resolvedURL: base + suffix,
                source: "service_ref"
            )
        }
    }

    private static func normalizedPath(_ path: String) -> String {
        if path.isEmpty {
            return ""
        }
        if path.hasPrefix("/") {
            return path
        }
        return "/" + path
    }

    private static func sanitizedServiceFilename(_ value: String) -> String {
        value.replacingOccurrences(of: "/", with: "__")
    }

    private static func writeRuntimeClaudeCodePlugin(
        serviceID: String,
        assignedSkillIDs: [String],
        workspaceSkillsByID: [String: WorkspaceSkillConfig],
        workspaceRoot: String,
        executionRootPath: String,
        outputRoot: URL,
        template: ClaudeCodePluginTemplate,
        binding: ClaudeCodePluginBinding
    ) throws {
        let workspaceSkillsRoot = SkillBundleLoader.workspaceSkillsRootURL(workspaceRoot: workspaceRoot)
        let executionRootURL = URL(fileURLWithPath: executionRootPath)
        let serviceOutputRoot = ClaudeCodePluginBundle.pluginRootURL(baseURL: outputRoot, serviceID: serviceID)

        try FileManager.default.createDirectory(at: serviceOutputRoot, withIntermediateDirectories: true)
        let rendered = try ClaudeCodePluginBundle.render(template: template, binding: binding)
        for file in rendered.files {
            let destinationURL = serviceOutputRoot.appendingPathComponent(file.relativePath, isDirectory: false)
            try FileManager.default.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try file.content.write(to: destinationURL, options: .atomic)
        }

        for projection in runtimeSkillProjectionDirectories {
            let stagedDirectoryURL = serviceOutputRoot.appendingPathComponent(projection.stagedRootPath, isDirectory: true)
            let existingDirectoryURL = executionRootURL.appendingPathComponent(projection.executionRootPath, isDirectory: true)
            try mergeDirectoryContentsIfPresent(from: existingDirectoryURL, to: stagedDirectoryURL)
        }

        for skillID in assignedSkillIDs {
            let bundleFiles = try SkillBundleLoader.bundleFiles(
                id: skillID,
                rootURL: workspaceSkillsRoot,
                fallback: workspaceSkillsByID[skillID]
            )

            for projection in runtimeSkillProjectionDirectories {
                let skillRootURL = serviceOutputRoot
                    .appendingPathComponent(projection.skillInsertionPath, isDirectory: true)
                    .appendingPathComponent(skillID, isDirectory: true)
                try FileManager.default.createDirectory(at: skillRootURL, withIntermediateDirectories: true)

                for file in bundleFiles {
                    let destinationURL = skillRootURL.appendingPathComponent(file.relativePath, isDirectory: false)
                    try FileManager.default.createDirectory(
                        at: destinationURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try file.content.write(to: destinationURL, options: .atomic)
                }
            }
        }

        let usageURL = serviceOutputRoot.appendingPathComponent(ClaudeCodePluginBundle.usageFileName, isDirectory: false)
        try ClaudeCodePluginBundle
            .usageDocument(pluginRootPath: serviceOutputRoot.path)
            .write(to: usageURL, atomically: true, encoding: .utf8)
    }

    private static func mergeDirectoryContentsIfPresent(from sourceURL: URL, to destinationURL: URL) throws {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: sourceURL.path(percentEncoded: false), isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return
        }

        try fm.createDirectory(at: destinationURL, withIntermediateDirectories: true)

        guard let enumerator = fm.enumerator(
            at: sourceURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsPackageDescendants]
        ) else {
            return
        }

        while let item = enumerator.nextObject() as? URL {
            let relativeComponents = item.standardizedFileURL.pathComponents.dropFirst(
                sourceURL.standardizedFileURL.pathComponents.count
            )
            guard !relativeComponents.isEmpty else { continue }
            let fileName = item.lastPathComponent
            if fileName == ".DS_Store" || fileName == ".git" {
                continue
            }

            let destinationItemURL = destinationURL.appendingPathComponent(relativeComponents.joined(separator: "/"))
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values.isDirectory == true {
                try fm.createDirectory(at: destinationItemURL, withIntermediateDirectories: true)
                continue
            }
            guard values.isRegularFile == true else { continue }

            try fm.createDirectory(
                at: destinationItemURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try Data(contentsOf: item)
            try data.write(to: destinationItemURL, options: .atomic)
        }
    }

    // MARK: - Service Deploy Metadata Resolution

    /// Build metadata for an inline service by matching its run command to a detection result.
    private static func resolveServiceMetadata(
        inline: WorkspaceRepoServiceConfig,
        repo: WorkspaceRepo,
        workspaceRoot: String,
        detectionsByRuntime: [RuntimeKind: RuntimeDetectionResult]
    ) -> ServiceDeployMetadata {
        let runtime = RuntimeKind.fromCommand(inline.run.first ?? "")
        let detection = detectionsByRuntime[runtime]
        let packageName = resolvePackageName(
            runtime: runtime,
            detection: detection,
            runCommand: inline.run,
            fallback: inline.id
        )
        let dockerfilePath = findDockerfilePath(
            repoPath: repo.path,
            runtime: runtime,
            workspaceRoot: workspaceRoot
        )
        return ServiceDeployMetadata(
            runtime: detection?.runtime ?? runtime,
            packageManager: detection?.packageManager ?? .unknown,
            packageName: packageName,
            repoPath: repo.path,
            dockerfilePath: dockerfilePath,
            executionRootPath: resolveExecutionRootPath(
                inlineCWD: inline.cwd,
                repoPath: repo.path,
                workspaceRoot: workspaceRoot
            )
        )
    }

    /// Resolve a human-readable package name from detection results.
    /// - 1:1 runtime (Node/Python/Deno): uses the single serviceNames entry
    /// - 1:N runtime (Swift): matches run command target to serviceNames
    /// - Fallback: uses the provided fallback string
    static func resolvePackageName(
        runtime: RuntimeKind,
        detection: RuntimeDetectionResult?,
        runCommand: [String],
        fallback: String
    ) -> String {
        guard let names = detection?.serviceNames, !names.isEmpty else {
            return fallback
        }
        if names.count == 1 {
            return names[0]
        }
        // Multiple names (Swift targets) — match via run command
        if runtime == .swift, runCommand.count >= 3, runCommand[1] == "run" {
            let target = runCommand[2]
            if names.contains(target) {
                return target
            }
        }
        // Try matching fallback (local ID) against known names
        if names.contains(fallback) {
            return fallback
        }
        return names[0]
    }

    /// Find a custom Dockerfile for this service's runtime.
    /// Priority: Dockerfile.{runtime} > Dockerfile > nil
    private static func findDockerfilePath(
        repoPath: String,
        runtime: RuntimeKind,
        workspaceRoot: String
    ) -> String? {
        let repoURL = URL(fileURLWithPath: workspaceRoot).appendingPathComponent(repoPath)
        let runtimeDockerfile = repoURL.appendingPathComponent("Dockerfile.\(runtime.rawValue)")
        if FileManager.default.fileExists(atPath: runtimeDockerfile.path) {
            return "\(repoPath)/Dockerfile.\(runtime.rawValue)"
        }
        let plainDockerfile = repoURL.appendingPathComponent("Dockerfile")
        if FileManager.default.fileExists(atPath: plainDockerfile.path) {
            return "\(repoPath)/Dockerfile"
        }
        return nil
    }

    private static func resolveExecutionRootPath(
        inlineCWD: String?,
        repoPath: String,
        workspaceRoot: String
    ) -> String {
        let repoURL = URL(fileURLWithPath: repoPath, relativeTo: URL(fileURLWithPath: workspaceRoot))
            .standardizedFileURL
        guard let inlineCWD, !inlineCWD.isEmpty else {
            return repoURL.path(percentEncoded: false)
        }
        return URL(fileURLWithPath: inlineCWD, relativeTo: repoURL)
            .standardizedFileURL
            .path(percentEncoded: false)
    }
}

private extension WorkspaceSyncer {
    struct SourceAuthAnalysisResult {
        var requirements: [WorkspaceSourceAuthRequirement]
        var warnings: [String]
    }

    struct RequirementAccumulator {
        var serviceIDs: Set<String>
        var repoPath: String
        var host: String
        var findings: [AIBSourceDependencyFinding]
        var hasLocalCredential: Bool
        var hasCloudCredential: Bool
        var suggestedPrivateKeySecretName: String
        var suggestedKnownHostsSecretName: String?
    }

    static func analyzeSourceAuthRequirements(
        services: [ServiceConfig],
        serviceMetadata: [String: ServiceDeployMetadata],
        workspaceRoot: String
    ) -> SourceAuthAnalysisResult {
        var warnings: [String] = []

        let localSourceCredentials: [AIBSourceCredential]
        do {
            localSourceCredentials = try loadTargetSourceCredentials(
                workspaceRoot: workspaceRoot,
                providerID: "local"
            )
        } catch {
            localSourceCredentials = []
            warnings.append("Failed to inspect local source credentials: \(error.localizedDescription)")
        }

        let cloudSourceCredentials: [AIBSourceCredential]
        do {
            cloudSourceCredentials = try loadTargetSourceCredentials(
                workspaceRoot: workspaceRoot,
                providerID: "gcp-cloudrun"
            )
        } catch {
            cloudSourceCredentials = []
            warnings.append("Failed to inspect gcp-cloudrun source credentials: \(error.localizedDescription)")
        }

        var accumulators: [String: RequirementAccumulator] = [:]

        for service in services {
            let serviceID = service.id.rawValue
            guard let metadata = serviceMetadata[serviceID], metadata.runtime == .node else {
                continue
            }

            let repoRoot = URL(fileURLWithPath: workspaceRoot)
                .appendingPathComponent(metadata.repoPath)
                .standardizedFileURL
                .path

            let findings: [AIBSourceDependencyFinding]
            do {
                findings = try AIBSourceDependencyAnalyzer.nodeGitDependencies(repoRoot: repoRoot)
            } catch {
                warnings.append(
                    "Service '\(serviceID)': failed to inspect private source dependencies: \(error.localizedDescription)"
                )
                continue
            }

            for finding in findings {
                let key = sourceAuthRequirementKey(repoPath: metadata.repoPath, host: finding.host)
                var accumulator = accumulators[key] ?? RequirementAccumulator(
                    serviceIDs: [],
                    repoPath: metadata.repoPath,
                    host: finding.host,
                    findings: [],
                    hasLocalCredential: false,
                    hasCloudCredential: false,
                    suggestedPrivateKeySecretName: AIBSourceCredentialNaming.suggestedPrivateKeySecretName(
                        workspaceRoot: workspaceRoot,
                        host: finding.host
                    ),
                    suggestedKnownHostsSecretName: AIBSourceCredentialNaming.suggestedKnownHostsSecretName(
                        workspaceRoot: workspaceRoot,
                        host: finding.host
                    )
                )

                accumulator.serviceIDs.insert(serviceID)
                if !accumulator.findings.contains(finding) {
                    accumulator.findings.append(finding)
                }
                if AIBSourceDependencyAnalyzer.matchingLocalCredential(
                    for: finding,
                    in: localSourceCredentials
                ) != nil {
                    accumulator.hasLocalCredential = true
                }
                if AIBSourceDependencyAnalyzer.matchingCloudCredential(
                    for: finding,
                    in: cloudSourceCredentials
                ) != nil {
                    accumulator.hasCloudCredential = true
                }
                accumulators[key] = accumulator
            }
        }

        let requirements = accumulators.values
            .map { accumulator in
                WorkspaceSourceAuthRequirement(
                    serviceIDs: accumulator.serviceIDs.sorted(),
                    repoPath: accumulator.repoPath,
                    host: accumulator.host,
                    findings: accumulator.findings.sorted {
                        if $0.sourceFile == $1.sourceFile {
                            return $0.requirement < $1.requirement
                        }
                        return $0.sourceFile < $1.sourceFile
                    },
                    hasLocalCredential: accumulator.hasLocalCredential,
                    hasCloudCredential: accumulator.hasCloudCredential,
                    suggestedPrivateKeySecretName: accumulator.suggestedPrivateKeySecretName,
                    suggestedKnownHostsSecretName: accumulator.suggestedKnownHostsSecretName
                )
            }
            .sorted {
                if $0.repoPath == $1.repoPath {
                    return $0.host.localizedStandardCompare($1.host) == .orderedAscending
                }
                return $0.repoPath.localizedStandardCompare($1.repoPath) == .orderedAscending
            }

        warnings.append(contentsOf: sourceAuthWarnings(for: requirements))
        return SourceAuthAnalysisResult(requirements: requirements, warnings: warnings)
    }

    static func sourceAuthWarnings(for requirements: [WorkspaceSourceAuthRequirement]) -> [String] {
        requirements.compactMap { requirement in
            guard !requirement.hasCloudCredential else { return nil }
            let serviceList = requirement.serviceIDs.joined(separator: ", ")
            let sourceFiles = requirement.findings.map(\.sourceFile).joined(separator: ", ")
            if requirement.hasLocalCredential {
                return """
                Private Git dependency detected for \(serviceList) (\(requirement.repoPath)) on host '\(requirement.host)' via \(sourceFiles). \
                Cloud Run source auth is not configured yet. Use Cloud Settings or the app quick setup to create Secret Manager entries.
                """
            }
            return """
            Private Git dependency detected for \(serviceList) (\(requirement.repoPath)) on host '\(requirement.host)' via \(sourceFiles). \
            Configure a matching local SSH credential in .aib/targets/local.yaml before provisioning gcp-cloudrun source auth.
            """
        }
    }

    static func sourceAuthRequirementKey(repoPath: String, host: String) -> String {
        "\(repoPath)|\(host.lowercased())"
    }

    static func loadTargetSourceCredentials(
        workspaceRoot: String,
        providerID: String
    ) throws -> [AIBSourceCredential] {
        let targetURL = URL(fileURLWithPath: workspaceRoot)
            .appendingPathComponent(".aib/targets/\(providerID).yaml")
        guard FileManager.default.fileExists(atPath: targetURL.path) else {
            return []
        }

        let content = try String(contentsOf: targetURL, encoding: .utf8)
        guard let node = try compose(yaml: content), let root = node.mapping else {
            return []
        }
        guard let sourceCredentialNodes = root["sourceCredentials"]?.sequence ?? root["source_credentials"]?.sequence else {
            return []
        }

        return sourceCredentialNodes.compactMap { credentialNode in
            guard let credentialMap = credentialNode.mapping else { return nil }
            let typeValue = credentialMap["type"]?.scalar?.string ?? AIBSourceCredentialType.ssh.rawValue
            let host = credentialMap["host"]?.scalar?.string ?? "github.com"
            guard let type = AIBSourceCredentialType(rawValue: typeValue) else { return nil }
            return AIBSourceCredential(
                type: type,
                host: host,
                localPrivateKeyPath: credentialMap["localPrivateKeyPath"]?.scalar?.string
                    ?? credentialMap["local_private_key_path"]?.scalar?.string,
                localKnownHostsPath: credentialMap["localKnownHostsPath"]?.scalar?.string
                    ?? credentialMap["local_known_hosts_path"]?.scalar?.string,
                localPrivateKeyPassphraseEnv: credentialMap["localPrivateKeyPassphraseEnv"]?.scalar?.string
                    ?? credentialMap["local_private_key_passphrase_env"]?.scalar?.string,
                localAccessTokenEnv: credentialMap["localAccessTokenEnv"]?.scalar?.string
                    ?? credentialMap["local_access_token_env"]?.scalar?.string,
                cloudPrivateKeySecret: credentialMap["cloudPrivateKeySecret"]?.scalar?.string
                    ?? credentialMap["cloud_private_key_secret"]?.scalar?.string,
                cloudKnownHostsSecret: credentialMap["cloudKnownHostsSecret"]?.scalar?.string
                    ?? credentialMap["cloud_known_hosts_secret"]?.scalar?.string
            )
        }
    }
}

private let runtimeSkillProjectionDirectories: [(
    executionRootPath: String,
    stagedRootPath: String,
    skillInsertionPath: String
)] = [
    (executionRootPath: ".claude", stagedRootPath: ".claude", skillInsertionPath: ".claude/skills"),
    (executionRootPath: ".agents", stagedRootPath: ".agents", skillInsertionPath: ".agents/skills"),
    (executionRootPath: "skills", stagedRootPath: "skills", skillInsertionPath: "skills"),
]

private struct RuntimeConnectionArtifact: Codable {
    var serviceID: String
    var mcpServers: [ResolvedConnectionTarget]
    var a2aAgents: [ResolvedConnectionTarget]

    enum CodingKeys: String, CodingKey {
        case serviceID = "service_id"
        case mcpServers = "mcp_servers"
        case a2aAgents = "a2a_agents"
    }
}

private struct ResolvedConnectionTarget: Codable {
    var serviceRef: String?
    var resolvedURL: String
    var source: String

    enum CodingKeys: String, CodingKey {
        case serviceRef = "service_ref"
        case resolvedURL = "resolved_url"
        case source
    }
}
