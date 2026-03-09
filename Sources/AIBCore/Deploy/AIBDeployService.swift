import AIBConfig
import AIBWorkspace
import Foundation
import Yams

/// Public facade for deployment operations.
/// Provider-agnostic: all cloud-specific logic is delegated to DeploymentProvider.
public enum AIBDeployService {

    // MARK: - Preflight

    /// Run preflight dependency checks for the given provider and return the aggregated report.
    public static func preflightCheck(provider: any DeploymentProvider) async -> PreflightReport {
        let runner = PreflightRunner(
            checkers: provider.preflightCheckers(),
            dependencies: provider.preflightDependencies()
        )
        var report: PreflightReport?
        for await event in runner.run() {
            if case .allCompleted(let r) = event {
                report = r
            }
        }
        return report ?? PreflightReport(results: [])
    }

    /// Run only the prerequisite tool-installation checks for the given provider.
    /// Returns results for prerequisite check IDs only (e.g., dockerInstalled, gcloudInstalled).
    /// Lightweight alternative to `preflightCheck(provider:)` for toolbar status indicators.
    public static func checkPrerequisites(provider: any DeploymentProvider) async -> [PreflightCheckResult] {
        let prerequisiteIDs = provider.prerequisiteCheckIDs
        let checkers = provider.preflightCheckers().filter { prerequisiteIDs.contains($0.checkID) }

        return await withTaskGroup(of: PreflightCheckResult.self, returning: [PreflightCheckResult].self) { group in
            for checker in checkers {
                group.addTask { await checker.run() }
            }
            var results: [PreflightCheckResult] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
    }

    // MARK: - Target Config

    /// Load the deploy target configuration.
    /// Looks for `.aib/targets/{providerID}.yaml` and merges with defaults.
    public static func loadTargetConfig(
        workspaceRoot: String,
        providerID: String,
        overrides: [String: String] = [:]
    ) throws -> AIBDeployTargetConfig {
        let targetPath = URL(fileURLWithPath: workspaceRoot)
            .appendingPathComponent(".aib/targets/\(providerID).yaml")
            .path

        var region = overrides["region"] ?? "us-central1"
        var auth: AIBDeployAuthMode = .private
        var providerConfig: [String: String] = overrides

        if FileManager.default.fileExists(atPath: targetPath) {
            let content = try String(contentsOfFile: targetPath, encoding: .utf8)
            if let yaml = try Yams.load(yaml: content) as? [String: Any],
               let defaults = yaml["defaults"] as? [String: Any]
            {
                if let r = defaults["region"] as? String, overrides["region"] == nil {
                    region = r
                }
                if let a = defaults["auth"] as? String {
                    auth = AIBDeployAuthMode(rawValue: a) ?? .private
                }
                // Merge any additional keys from YAML into providerConfig
                for (key, value) in defaults {
                    if key != "region" && key != "auth", let strVal = value as? String {
                        if providerConfig[key] == nil {
                            providerConfig[key] = strVal
                        }
                    }
                }
            }
            // Top-level keys (e.g., gcpProject, artifactRegistryHost)
            if let yaml = try Yams.load(yaml: content) as? [String: Any] {
                for (key, value) in yaml where key != "defaults" {
                    if let strVal = value as? String, providerConfig[key] == nil {
                        providerConfig[key] = strVal
                    }
                }
            }
        }

        return AIBDeployTargetConfig(
            providerID: providerID,
            region: region,
            defaultAuth: auth,
            providerConfig: providerConfig
        )
    }

    // MARK: - Plan Generation

    /// Generate a deploy plan from the workspace topology using the given provider.
    /// Runtime detection is performed once by `WorkspaceSyncer.resolveConfig()` and
    /// carried forward via `ResolvedConfig.serviceMetadata` — no duplicate detection.
    public static func generatePlan(
        workspaceRoot: String,
        targetConfig: AIBDeployTargetConfig,
        provider: any DeploymentProvider
    ) async throws -> AIBDeployPlan {
        let workspacePath = AIBRuntimeCoreService.workspaceYAMLPath(workspaceRoot: workspaceRoot)
        let workspace = try WorkspaceYAMLCodec.loadWorkspace(at: workspacePath)
        let resolved = try WorkspaceSyncer.resolveConfig(workspaceRoot: workspaceRoot, workspace: workspace)

        // Build service name mapping from pre-resolved metadata
        var serviceNameMap: [String: String] = [:]
        for service in resolved.config.services {
            let meta = resolved.serviceMetadata[service.id.rawValue]
            let packageName = meta?.packageName
                ?? service.id.rawValue.split(separator: "/").last.map(String.init)
                ?? service.id.rawValue
            serviceNameMap[service.id.rawValue] = provider.deployedServiceName(from: packageName)
        }

        // Query live URLs of already-deployed services for accurate connection resolution
        var existingServiceURLs: [String: String] = [:]
        for (serviceRef, deployedName) in serviceNameMap {
            if let liveURL = await provider.existingServiceURL(
                serviceName: deployedName,
                targetConfig: targetConfig
            ) {
                existingServiceURLs[serviceRef] = liveURL
            }
        }

        var servicePlans: [AIBDeployServicePlan] = []
        var authBindings: [AIBDeployAuthBinding] = []
        let warnings: [String] = []
        var fatalErrors: [String] = []

        for service in resolved.config.services {
            let deployedName = serviceNameMap[service.id.rawValue] ?? service.id.rawValue
            let meta = resolved.serviceMetadata[service.id.rawValue]
            let runtime = meta?.runtime ?? .unknown
            let repoPath = meta?.repoPath ?? ""

            // Resolve Dockerfile using metadata
            let dockerfile: AIBDeployArtifact
            do {
                dockerfile = try resolveDockerfile(
                    meta: meta,
                    runtime: runtime,
                    repoPath: repoPath,
                    service: service,
                    workspaceRoot: workspaceRoot
                )
            } catch {
                fatalErrors.append(
                    "Service '\(service.id.rawValue)': \(error.localizedDescription)"
                )
                continue
            }

            // Resolve connections using provider
            var resolvedConnections = AIBDeployResolvedConnections()

            for mcpTarget in service.connections.mcpServers {
                if let url = mcpTarget.url, !url.isEmpty {
                    resolvedConnections.mcpServers.append(AIBDeployConnectionEntry(
                        serviceRef: url,
                        deployedServiceName: "",
                        resolvedURL: url
                    ))
                } else if let ref = mcpTarget.serviceRef, !ref.isEmpty {
                    guard let targetService = resolved.config.services.first(where: { $0.id.rawValue == ref }) else {
                        fatalErrors.append(
                            "Service '\(service.id.rawValue)': mcp_servers references unknown service '\(ref)'."
                        )
                        continue
                    }
                    let mcpPath = targetService.mcp?.path ?? "/mcp"
                    let resolvedURL = provider.resolveURL(
                        serviceRef: ref,
                        region: targetConfig.region,
                        path: mcpPath,
                        serviceNameMap: serviceNameMap,
                        existingServiceURLs: existingServiceURLs
                    )
                    resolvedConnections.mcpServers.append(AIBDeployConnectionEntry(
                        serviceRef: ref,
                        deployedServiceName: serviceNameMap[ref] ?? ref,
                        resolvedURL: resolvedURL
                    ))

                    let targetDeployedName = serviceNameMap[ref] ?? ref
                    authBindings.append(AIBDeployAuthBinding(
                        sourceServiceName: deployedName,
                        targetServiceName: targetDeployedName,
                        member: provider.authBindingMember(
                            sourceServiceName: deployedName,
                            targetConfig: targetConfig
                        )
                    ))
                }
            }

            for a2aTarget in service.connections.a2aAgents {
                if let url = a2aTarget.url, !url.isEmpty {
                    resolvedConnections.a2aAgents.append(AIBDeployConnectionEntry(
                        serviceRef: url,
                        deployedServiceName: "",
                        resolvedURL: url
                    ))
                } else if let ref = a2aTarget.serviceRef, !ref.isEmpty {
                    guard let targetService = resolved.config.services.first(where: { $0.id.rawValue == ref }) else {
                        fatalErrors.append(
                            "Service '\(service.id.rawValue)': a2a_agents references unknown service '\(ref)'."
                        )
                        continue
                    }
                    let a2aPath = targetService.a2a?.rpcPath ?? "/a2a"
                    let resolvedURL = provider.resolveURL(
                        serviceRef: ref,
                        region: targetConfig.region,
                        path: a2aPath,
                        serviceNameMap: serviceNameMap,
                        existingServiceURLs: existingServiceURLs
                    )
                    resolvedConnections.a2aAgents.append(AIBDeployConnectionEntry(
                        serviceRef: ref,
                        deployedServiceName: serviceNameMap[ref] ?? ref,
                        resolvedURL: resolvedURL
                    ))
                }
            }

            // Build env vars — merge workspace.yaml service.env first, then add generated vars
            var envVars: [String: String] = service.env
            if !resolvedConnections.mcpServers.isEmpty {
                let urls = resolvedConnections.mcpServers.map(\.resolvedURL).joined(separator: ",")
                envVars["MCP_SERVER_URLS"] = urls
                // Tell the agent where to find the bundled connection config
                envVars["AIB_CONNECTIONS_FILE"] = "/app/.aib-connections.json"
            }

            // Scan source for env var references to detect secrets and missing vars
            let detectedVars = EnvVarScanner.scan(
                repoPath: repoPath,
                workspaceRoot: workspaceRoot,
                runtime: runtime
            )
            let requiredSecrets = detectedVars
                .filter { $0.kind == .secret }
                .map(\.name)
            let missingRegularVars = detectedVars
                .filter { $0.kind == .regular }
                .filter { !envVars.keys.contains($0.name) }
                .map(\.name)
            let envWarnings = missingRegularVars.map {
                "Environment variable '\($0)' referenced in source but not configured in workspace.yaml env."
            }

            let resourceConfig = AIBDeployResourceConfig(
                memory: targetConfig.defaultMemory,
                cpu: targetConfig.defaultCPU,
                maxInstances: targetConfig.defaultMaxInstances,
                concurrency: targetConfig.defaultConcurrency,
                timeout: targetConfig.defaultTimeout
            )
            let isPublic = targetConfig.defaultAuth == .public

            // Generate MCP connection config for agents
            var mcpConnectionArtifact: AIBDeployArtifact?
            if service.kind == .agent, !resolvedConnections.mcpServers.isEmpty {
                let mcpServers = resolvedConnections.mcpServers.map {
                    (serviceRef: $0.serviceRef, resolvedURL: $0.resolvedURL)
                }
                let a2aAgents = resolvedConnections.a2aAgents.map {
                    (serviceRef: $0.serviceRef, resolvedURL: $0.resolvedURL)
                }
                let connectionJSON = try MCPConnectionConfigGenerator.generate(
                    serviceID: service.id.rawValue,
                    mcpServers: mcpServers,
                    a2aAgents: a2aAgents
                )
                mcpConnectionArtifact = AIBDeployArtifact(
                    relativePath: "services/\(deployedName)/connections.json",
                    content: connectionJSON,
                    source: .generated
                )
            }

            var servicePlan = AIBDeployServicePlan(
                id: service.id.rawValue,
                serviceKind: AIBServiceKind(from: service.kind),
                runtime: runtime.rawValue,
                repoPath: repoPath,
                deployedServiceName: deployedName,
                region: targetConfig.region,
                artifacts: AIBDeployArtifactSet(
                    dockerfile: dockerfile,
                    deployConfig: AIBDeployArtifact(relativePath: "", content: "", source: .generated),
                    mcpConnectionConfig: mcpConnectionArtifact
                ),
                resourceConfig: resourceConfig,
                envVars: envVars,
                connections: resolvedConnections,
                isPublic: isPublic,
                requiredSecrets: requiredSecrets,
                envWarnings: envWarnings
            )

            let deployConfigContent = provider.generateDeployConfig(service: servicePlan)
            servicePlan.artifacts.deployConfig = AIBDeployArtifact(
                relativePath: "services/\(deployedName)/deploy.yaml",
                content: deployConfigContent,
                source: .generated
            )

            servicePlans.append(servicePlan)
        }

        if !fatalErrors.isEmpty {
            throw AIBDeployError(
                phase: "plan",
                message: fatalErrors.joined(separator: "\n")
            )
        }

        // Deduplicate auth bindings
        let uniqueBindings = Array(Set(authBindings.map { "\($0.sourceServiceName)->\($0.targetServiceName)" })
            .compactMap { key -> AIBDeployAuthBinding? in
                authBindings.first(where: { "\($0.sourceServiceName)->\($0.targetServiceName)" == key })
            })

        return AIBDeployPlan(
            workspaceName: workspace.workspaceName,
            targetConfig: targetConfig,
            services: servicePlans,
            authBindings: uniqueBindings,
            warnings: warnings
        )
    }

    // MARK: - Dockerfile Resolution

    /// Resolve a Dockerfile for a service.
    /// Priority: Dockerfile.{runtime} (custom) > Dockerfile (custom) > auto-generate
    private static func resolveDockerfile(
        meta: ServiceDeployMetadata?,
        runtime: RuntimeKind,
        repoPath: String,
        service: ServiceConfig,
        workspaceRoot: String
    ) throws -> AIBDeployArtifact {
        let repoURL = URL(fileURLWithPath: workspaceRoot).appendingPathComponent(repoPath)

        // Priority 1: runtime-specific Dockerfile (e.g., Dockerfile.node, Dockerfile.swift)
        let runtimeDockerfilePath = repoURL.appendingPathComponent("Dockerfile.\(runtime.rawValue)")
        if FileManager.default.fileExists(atPath: runtimeDockerfilePath.path) {
            let content = try String(contentsOfFile: runtimeDockerfilePath.path, encoding: .utf8)
            return AIBDeployArtifact(
                relativePath: "\(repoPath)/Dockerfile.\(runtime.rawValue)",
                content: content,
                source: .custom
            )
        }

        // Priority 2: plain Dockerfile
        let plainDockerfilePath = repoURL.appendingPathComponent("Dockerfile")
        if FileManager.default.fileExists(atPath: plainDockerfilePath.path) {
            let content = try String(contentsOfFile: plainDockerfilePath.path, encoding: .utf8)
            return AIBDeployArtifact(
                relativePath: "\(repoPath)/Dockerfile",
                content: content,
                source: .custom
            )
        }

        // Priority 3: auto-generate using runtime-specific generator
        guard let generator = DockerfileGeneratorRegistry.generator(for: runtime) else {
            throw AIBDeployError(
                phase: "plan",
                message: "No Dockerfile found and no generator for runtime '\(runtime.rawValue)'. "
                    + "Add a Dockerfile to '\(repoPath)/' or use a supported runtime."
            )
        }
        let content = generator.generate(
            servicePath: repoURL,
            runCommand: service.run,
            buildCommand: nil,
            installCommand: nil,
            port: 8080
        )
        return AIBDeployArtifact(
            relativePath: "\(repoPath)/Dockerfile.\(runtime.rawValue)",
            content: content,
            source: .generated
        )
    }

    // MARK: - Write Artifacts

    /// Write generated artifacts to disk.
    public static func writeArtifacts(
        plan: AIBDeployPlan,
        workspaceRoot: String
    ) throws {
        let fm = FileManager.default
        let deployDir = URL(fileURLWithPath: workspaceRoot)
            .appendingPathComponent(".aib/generated/deploy")

        // Clean and recreate deploy directory
        if fm.fileExists(atPath: deployDir.path) {
            try fm.removeItem(at: deployDir)
        }
        try fm.createDirectory(at: deployDir, withIntermediateDirectories: true)

        for service in plan.services {
            // Write generated Dockerfile using artifact's relativePath
            if service.artifacts.dockerfile.source == .generated {
                let dockerfileDest = URL(fileURLWithPath: workspaceRoot)
                    .appendingPathComponent(service.artifacts.dockerfile.relativePath)
                try service.artifacts.dockerfile.content.write(
                    to: dockerfileDest,
                    atomically: true,
                    encoding: .utf8
                )
            }

            try ensureDeployDockerignore(
                runtime: service.runtime,
                repoPath: service.repoPath,
                workspaceRoot: workspaceRoot
            )

            // Write deploy config to deploy directory
            let serviceDeployDir = deployDir.appendingPathComponent("services/\(service.deployedServiceName)")
            try fm.createDirectory(at: serviceDeployDir, withIntermediateDirectories: true)

            try service.artifacts.deployConfig.content.write(
                to: serviceDeployDir.appendingPathComponent("deploy.yaml"),
                atomically: true,
                encoding: .utf8
            )

            // Write MCP connection config if applicable
            if let mcpConfig = service.artifacts.mcpConnectionConfig {
                try mcpConfig.content.write(
                    to: serviceDeployDir.appendingPathComponent("connections.json"),
                    atomically: true,
                    encoding: .utf8
                )
            }
        }

        // Write plan.json
        let summary: [String: Any] = [
            "workspace_name": plan.workspaceName,
            "provider": plan.targetConfig.providerID,
            "services_count": plan.services.count,
            "auth_bindings_count": plan.authBindings.count,
            "timestamp": ISO8601DateFormatter().string(from: plan.timestamp),
        ]
        let data = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: deployDir.appendingPathComponent("plan.json"))

        // Write auth bindings
        if !plan.authBindings.isEmpty {
            let bindingsDir = deployDir.appendingPathComponent("auth")
            try fm.createDirectory(at: bindingsDir, withIntermediateDirectories: true)

            var lines = ["# Generated auth bindings"]
            for binding in plan.authBindings {
                lines.append("- source: \(binding.sourceServiceName)")
                lines.append("  target: \(binding.targetServiceName)")
                lines.append("  role: \(binding.role)")
                lines.append("  member: \(binding.member)")
            }
            try lines.joined(separator: "\n").write(
                to: bindingsDir.appendingPathComponent("bindings.yaml"),
                atomically: true,
                encoding: .utf8
            )
        }
    }

    /// Ensure `.dockerignore` is deploy-safe for context size.
    /// Missing file: create with defaults.
    /// Existing file: keep user rules, append required excludes if missing.
    private static func ensureDeployDockerignore(
        runtime: String,
        repoPath: String,
        workspaceRoot: String
    ) throws {
        let repoURL = URL(fileURLWithPath: workspaceRoot).appendingPathComponent(repoPath)
        let dockerignoreURL = repoURL.appendingPathComponent(".dockerignore")

        let runtimeSpecific: [String]
        switch runtime {
        case "swift":
            runtimeSpecific = [
                ".build/",
                ".swiftpm",
                "DerivedData",
            ]
        case "node":
            runtimeSpecific = [
                "node_modules",
                ".next",
                ".turbo",
                "coverage",
            ]
        case "python":
            runtimeSpecific = [
                ".venv",
                "__pycache__",
                ".pytest_cache",
                ".mypy_cache",
            ]
        default:
            runtimeSpecific = []
        }

        let requiredCommon = [
            ".git",
            ".aib",
            ".DS_Store",
            ".idea",
            ".vscode",
        ]
        let requiredRules = requiredCommon + runtimeSpecific

        let existing: String
        if FileManager.default.fileExists(atPath: dockerignoreURL.path) {
            existing = try String(contentsOf: dockerignoreURL, encoding: .utf8)
        } else {
            existing = ""
        }

        var currentLines = existing.components(separatedBy: .newlines)
        let normalizedExisting = Set(
            currentLines.compactMap { normalizeDockerignoreRule($0) }
        )

        var missing: [String] = []
        for rule in requiredRules where !normalizedExisting.contains(normalizeDockerignoreComparable(rule)) {
            missing.append(rule)
        }

        if existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let header = [
                "# Generated by AIB to reduce deploy build context size.",
                "# You can add custom include/exclude rules below.",
            ]
            let content = (header + requiredRules).joined(separator: "\n") + "\n"
            try content.write(to: dockerignoreURL, atomically: true, encoding: .utf8)
            return
        }

        guard !missing.isEmpty else { return }

        if let last = currentLines.last, !last.isEmpty {
            currentLines.append("")
        }
        currentLines.append("# Added by AIB deploy (required excludes)")
        currentLines.append(contentsOf: missing)
        let updated = currentLines.joined(separator: "\n") + "\n"
        try updated.write(to: dockerignoreURL, atomically: true, encoding: .utf8)
    }
}

// MARK: - Helpers

private extension AIBServiceKind {
    init(from configKind: ServiceKind) {
        switch configKind {
        case .agent: self = .agent
        case .mcp: self = .mcp
        case .unknown: self = .unknown
        }
    }
}

private func normalizeDockerignoreRule(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
    return normalizeDockerignoreComparable(trimmed)
}

private func normalizeDockerignoreComparable(_ rule: String) -> String {
    var value = rule.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.hasPrefix("./") {
        value.removeFirst(2)
    }
    while value.hasPrefix("/") {
        value.removeFirst()
    }
    if value.hasSuffix("/") {
        value.removeLast()
    }
    return value
}
