import AIBConfig
import AIBRuntimeCore
import AIBWorkspace
import Foundation
import YAML

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
    /// Returns results for prerequisite check IDs only (e.g., buildBackendAvailable, gcloudInstalled).
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

        let isLocalProvider = providerID == "local"
        var region = overrides["region"] ?? (isLocalProvider ? "local" : "us-central1")
        var auth: AIBDeployAuthMode = .private
        var buildMode: AIBBuildMode = isLocalProvider ? .convenience : .strict
        var providerConfig: [String: String] = overrides
        var kindDefaults: [AIBServiceKind: AIBDeployResourceConfig] = [:]
        var sourceCredentials: [AIBSourceCredential] = []
        var convenience: AIBConvenienceOptions?

        if FileManager.default.fileExists(atPath: targetPath) {
            let content = try String(contentsOfFile: targetPath, encoding: .utf8)
            if let node = try compose(yaml: content), let root = node.mapping {
                if let buildModeValue = root["buildMode"]?.scalar?.string ?? root["build_mode"]?.scalar?.string {
                    buildMode = AIBBuildMode(rawValue: buildModeValue) ?? .strict
                }

                if let sourceCredentialNodes = root["sourceCredentials"]?.sequence ?? root["source_credentials"]?.sequence {
                    sourceCredentials = sourceCredentialNodes.compactMap { credentialNode in
                        guard let credentialMap = credentialNode.mapping else { return nil }
                        let typeValue = credentialMap["type"]?.scalar?.string ?? AIBSourceCredentialType.ssh.rawValue
                        let host = credentialMap["host"]?.scalar?.string ?? "github.com"
                        return AIBSourceCredential(
                            type: AIBSourceCredentialType(rawValue: typeValue) ?? .ssh,
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

                if let convenienceMap = root["convenience"]?.mapping {
                    convenience = AIBConvenienceOptions(
                        useHostCorepackCache: parseBoolNode(convenienceMap["useHostCorepackCache"] ?? convenienceMap["use_host_corepack_cache"]) ?? true,
                        useHostPNPMStore: parseBoolNode(convenienceMap["useHostPNPMStore"] ?? convenienceMap["use_host_pnpm_store"]) ?? true,
                        useRepoLocalPNPMStore: parseBoolNode(convenienceMap["useRepoLocalPNPMStore"] ?? convenienceMap["use_repo_local_pnpm_store"]) ?? true
                    )
                }

                if let defaults = root["defaults"]?.mapping {
                    if let r = defaults["region"]?.scalar?.string, overrides["region"] == nil {
                        region = r
                    }
                    if let a = defaults["auth"]?.scalar?.string {
                        auth = AIBDeployAuthMode(rawValue: a) ?? .private
                    }

                    // Parse per-kind resource overrides
                    let kindKeys: [String: AIBServiceKind] = ["agent": .agent, "mcp": .mcp, "other": .unknown]
                    for (yamlKey, kind) in kindKeys {
                        if let kindNode = defaults[yamlKey]?.mapping {
                            kindDefaults[kind] = parseResourceConfig(from: kindNode, kind: kind)
                        }
                    }

                    // Merge remaining scalar keys into providerConfig (skip kind subsections)
                    let reservedKeys: Set<String> = ["region", "auth", "agent", "mcp", "other"]
                    for (key, value) in defaults {
                        guard let keyStr = key.scalar?.string else { continue }
                        if !reservedKeys.contains(keyStr),
                           let strVal = value.scalar?.string,
                           providerConfig[keyStr] == nil {
                            providerConfig[keyStr] = strVal
                        }
                    }
                }
                // Top-level keys (e.g., gcpProject, artifactRegistryHost)
                for (key, value) in root {
                    guard let keyStr = key.scalar?.string else { continue }
                    let reservedTopLevelKeys: Set<String> = [
                        "version", "target", "defaults",
                        "buildMode", "build_mode",
                        "sourceCredentials", "source_credentials",
                        "convenience",
                    ]
                    guard !reservedTopLevelKeys.contains(keyStr) else { continue }
                    if let strVal = value.scalar?.string, providerConfig[keyStr] == nil {
                        providerConfig[keyStr] = strVal
                    }
                }
            }
        }

        return AIBDeployTargetConfig(
            providerID: providerID,
            region: region,
            defaultAuth: auth,
            buildMode: buildMode,
            sourceCredentials: sourceCredentials,
            convenience: convenience,
            kindDefaults: kindDefaults,
            providerConfig: providerConfig
        )
    }

    /// Parse a YAML mapping into AIBDeployResourceConfig, using kind defaults as baseline.
    private static func parseResourceConfig(
        from mapping: Node.Mapping,
        kind: AIBServiceKind
    ) -> AIBDeployResourceConfig {
        let baseline = AIBDeployResourceConfig.defaults(for: kind)
        let memory = mapping["memory"]?.scalar?.string ?? baseline.memory
        let cpu = mapping["cpu"]?.scalar?.string ?? baseline.cpu
        let maxInstances = (mapping["max_instances"]?.scalar?.string).flatMap { Int($0) } ?? baseline.maxInstances
        let minInstances = (mapping["min_instances"]?.scalar?.string).flatMap { Int($0) } ?? baseline.minInstances
        let concurrency = (mapping["concurrency"]?.scalar?.string).flatMap { Int($0) } ?? baseline.concurrency
        let timeout = mapping["timeout"]?.scalar?.string ?? baseline.timeout
        return AIBDeployResourceConfig(
            memory: memory,
            cpu: cpu,
            maxInstances: maxInstances,
            minInstances: minInstances,
            concurrency: concurrency,
            timeout: timeout
        )
    }

    private static func parseBoolNode(_ node: Node?) -> Bool? {
        guard let stringValue = node?.scalar?.string else { return nil }
        switch stringValue.lowercased() {
        case "true", "yes", "on", "1":
            return true
        case "false", "no", "off", "0":
            return false
        default:
            return nil
        }
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
        let workspaceSkillsByID = Dictionary(uniqueKeysWithValues: (workspace.skills ?? []).map { ($0.id, $0) })
        let skillIDsByService = Dictionary(uniqueKeysWithValues: workspace.repos.flatMap { repo in
            (repo.services ?? []).map { service in
                ("\(repo.namespace)/\(service.id)", service.skills ?? [])
            }
        })

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
            let repoRoot = URL(fileURLWithPath: workspaceRoot)
                .appendingPathComponent(repoPath)
                .standardizedFileURL
                .path
            let sourceDependencies: [AIBSourceDependencyFinding]
            do {
                sourceDependencies = runtime == .node && !repoPath.isEmpty
                    ? try AIBSourceDependencyAnalyzer.nodeGitDependencies(repoRoot: repoRoot)
                    : []
            } catch {
                fatalErrors.append(
                    "Service '\(service.id.rawValue)': failed to inspect source dependencies: \(error.localizedDescription)"
                )
                continue
            }
            let cloudSourceCredential = sourceDependencies.first.flatMap {
                AIBSourceDependencyAnalyzer.matchingCloudCredential(for: $0, in: targetConfig.sourceCredentials)
            }

            do {
                try validateDeployableDependencies(
                    runtime: runtime,
                    repoPath: repoPath,
                    workspaceRoot: workspaceRoot,
                    providerID: provider.providerID,
                    sourceDependencies: sourceDependencies,
                    targetConfig: targetConfig
                )
            } catch {
                fatalErrors.append(
                    "Service '\(service.id.rawValue)': \(error.localizedDescription)"
                )
                continue
            }

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

            do {
                try validateCustomDockerfileContract(
                    serviceID: service.id.rawValue,
                    packageManager: meta?.packageManager ?? .unknown,
                    dockerfile: dockerfile,
                    sourceDependencies: sourceDependencies,
                    providerID: provider.providerID
                )
            } catch {
                fatalErrors.append(
                    "Service '\(service.id.rawValue)': \(error.localizedDescription)"
                )
                continue
            }

            let skillArtifacts: [AIBDeployArtifact]
            do {
                skillArtifacts = try resolveSkillArtifacts(
                    workspaceRoot: workspaceRoot,
                    assignedSkillIDs: skillIDsByService[service.id.rawValue] ?? [],
                    workspaceSkillsByID: workspaceSkillsByID
                )
            } catch {
                fatalErrors.append(
                    "Service '\(service.id.rawValue)': \(error.localizedDescription)"
                )
                continue
            }

            let executionDirectoryArtifacts: [AIBDeployArtifact]
            do {
                if service.kind == .agent {
                    executionDirectoryArtifacts = try resolveExecutionDirectoryArtifacts(
                        executionRootPath: meta?.executionRootPath
                            ?? URL(fileURLWithPath: repoPath, relativeTo: URL(fileURLWithPath: workspaceRoot))
                            .standardizedFileURL
                            .path(percentEncoded: false)
                    )
                } else {
                    executionDirectoryArtifacts = []
                }
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
                "Service '\(service.id.rawValue)': Environment variable '\($0)' referenced in source but not configured in workspace.yaml env."
            }

            let serviceKind = AIBServiceKind(from: service.kind)
            let resourceConfig = targetConfig.resourceConfig(for: serviceKind)
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

            let claudeCodePluginArtifacts: [AIBDeployArtifact]
            do {
                if service.kind == .agent {
                    claudeCodePluginArtifacts = try resolveClaudeCodePluginArtifacts(
                        serviceID: service.id.rawValue,
                        resolvedConnections: resolvedConnections,
                        skillArtifacts: skillArtifacts
                    )
                } else {
                    claudeCodePluginArtifacts = []
                }
            } catch {
                fatalErrors.append(
                    "Service '\(service.id.rawValue)': \(error.localizedDescription)"
                )
                continue
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
                    mcpConnectionConfig: mcpConnectionArtifact,
                    skillConfigs: skillArtifacts,
                    claudeCodePluginArtifacts: claudeCodePluginArtifacts,
                    executionDirectoryConfigs: executionDirectoryArtifacts
                ),
                resourceConfig: resourceConfig,
                envVars: envVars,
                connections: resolvedConnections,
                isPublic: isPublic,
                sourceDependencies: sourceDependencies,
                sourceCredential: cloudSourceCredential,
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
                try service.artifacts.dockerfile.content.write(to: dockerfileDest, options: .atomic)
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
                options: .atomic
            )

            // Write MCP connection config if applicable
            if let mcpConfig = service.artifacts.mcpConnectionConfig {
                try mcpConfig.content.write(
                    to: serviceDeployDir.appendingPathComponent("connections.json"),
                    options: .atomic
                )
            }

            if !service.artifacts.skillConfigs.isEmpty {
                let skillDir = serviceDeployDir.appendingPathComponent("skills")
                try fm.createDirectory(at: skillDir, withIntermediateDirectories: true)

                for artifact in service.artifacts.skillConfigs {
                    let destination = skillDir.appendingPathComponent(artifact.relativePath)
                    try fm.createDirectory(
                        at: destination.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try artifact.content.write(to: destination, options: .atomic)
                }
            }

            if !service.artifacts.claudeCodePluginArtifacts.isEmpty {
                let pluginDir = serviceDeployDir.appendingPathComponent("plugin")
                try fm.createDirectory(at: pluginDir, withIntermediateDirectories: true)

                for artifact in service.artifacts.claudeCodePluginArtifacts {
                    let destination = pluginDir.appendingPathComponent(artifact.relativePath)
                    try fm.createDirectory(
                        at: destination.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try artifact.content.write(to: destination, options: .atomic)
                }

                let usageURL = pluginDir.appendingPathComponent(ClaudeCodePluginBundle.usageFileName)
                try ClaudeCodePluginBundle
                    .usageDocument(pluginRootPath: pluginDir.path)
                    .write(to: usageURL, atomically: true, encoding: .utf8)
            }

            if !service.artifacts.executionDirectoryConfigs.isEmpty {
                let executionDir = serviceDeployDir.appendingPathComponent("execution-directory")
                try fm.createDirectory(at: executionDir, withIntermediateDirectories: true)

                for artifact in service.artifacts.executionDirectoryConfigs {
                    let destination = executionDir.appendingPathComponent(artifact.relativePath)
                    try fm.createDirectory(
                        at: destination.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try artifact.content.write(to: destination, options: .atomic)
                }
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

extension AIBDeployService {
    private static func validateDeployableDependencies(
        runtime: RuntimeKind,
        repoPath: String,
        workspaceRoot: String,
        providerID: String,
        sourceDependencies: [AIBSourceDependencyFinding],
        targetConfig: AIBDeployTargetConfig
    ) throws {
        guard providerID == "gcp-cloudrun", runtime == .node, !repoPath.isEmpty else { return }
        for dependency in sourceDependencies {
            guard AIBSourceDependencyAnalyzer.matchingCloudCredential(
                for: dependency,
                in: targetConfig.sourceCredentials
            ) != nil else {
                throw AIBDeployError(
                    phase: "plan",
                    message: """
                    Cloud Run image build requires explicit SSH source credentials for private Git dependencies. \
                    Missing cloud source credential for host '\(dependency.host)' referenced by \(repoPath)/\(dependency.sourceFile). \
                    Add a matching entry under sourceCredentials in .aib/targets/\(providerID).yaml with cloudPrivateKeySecret and optional cloudKnownHostsSecret.
                    """
                )
            }
        }
    }

    static func validateCustomDockerfileContract(
        serviceID: String,
        packageManager: PackageManagerKind,
        dockerfile: AIBDeployArtifact,
        sourceDependencies: [AIBSourceDependencyFinding],
        providerID: String
    ) throws {
        guard providerID == "gcp-cloudrun", dockerfile.source == .custom else { return }
        guard let content = dockerfile.utf8String else { return }

        if packageManager == .pnpm, content.localizedCaseInsensitiveContains("npm ci") {
            throw AIBDeployError(
                phase: "plan",
                message: """
                Custom Dockerfile \(dockerfile.relativePath) uses 'npm ci' but this service is detected as pnpm-managed. \
                Use pnpm-based install steps or remove the custom Dockerfile so AIB can generate one.
                """
            )
        }

        guard !sourceDependencies.isEmpty else { return }

        let installCommands = dockerfileInstallCommands(content)
        if let laterStageCommand = installCommands.first(where: { $0.stageIndex > 0 }) {
            throw AIBDeployError(
                phase: "plan",
                message: """
                Custom Dockerfile \(dockerfile.relativePath) re-installs dependencies in a later stage ('\(laterStageCommand.command)'). \
                For private Git dependencies, AIB only injects source auth into the initial build stage. Install dependencies once in the first stage and copy node_modules into later stages.
                """
            )
        }

        let lowercasedContent = content.lowercased()
        let hasSSHClientSupport =
            lowercasedContent.contains("openssh-client")
            || lowercasedContent.contains("ssh-client")
            || lowercasedContent.contains("/usr/bin/ssh")
            || lowercasedContent.contains(" gitsshcommand")
            || lowercasedContent.contains("git_ssh_command")
        if !installCommands.isEmpty, !hasSSHClientSupport {
            throw AIBDeployError(
                phase: "plan",
                message: """
                Custom Dockerfile \(dockerfile.relativePath) installs private Git dependencies but does not appear to install an SSH client. \
                Add openssh-client in the auth-enabled dependency stage, or remove the custom Dockerfile so AIB can generate a compatible one.
                """
            )
        }
    }

    private static func dockerfileInstallCommands(_ content: String) -> [(stageIndex: Int, command: String)] {
        let installMarkers = [
            "npm ci",
            "npm install",
            "pnpm install",
            "yarn install",
            "bun install",
        ]

        var stageIndex = -1
        var commands: [(stageIndex: Int, command: String)] = []

        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            if line.uppercased().hasPrefix("FROM ") {
                stageIndex += 1
                continue
            }

            guard line.uppercased().hasPrefix("RUN ") else { continue }
            let lowercasedLine = line.lowercased()
            if installMarkers.contains(where: { lowercasedLine.contains($0) }) {
                commands.append((stageIndex: max(stageIndex, 0), command: line))
            }
        }

        return commands
    }

    static let deployedSkillProjectionRoots: [String] = [
        "__aib_deploy/claude/skills",
        "__aib_deploy/agents/skills",
        "__aib_deploy/skills",
    ]

    static func resolveSkillArtifacts(
        workspaceRoot: String,
        assignedSkillIDs: [String],
        workspaceSkillsByID: [String: WorkspaceSkillConfig]
    ) throws -> [AIBDeployArtifact] {
        let workspaceSkillsRoot = SkillBundleLoader.workspaceSkillsRootURL(workspaceRoot: workspaceRoot)
        var artifacts: [AIBDeployArtifact] = []

        for skillID in assignedSkillIDs {
            let bundleFiles = try SkillBundleLoader.bundleFiles(
                id: skillID,
                rootURL: workspaceSkillsRoot,
                fallback: workspaceSkillsByID[skillID]
            )

            for root in deployedSkillProjectionRoots {
                for file in bundleFiles {
                    artifacts.append(AIBDeployArtifact(
                        relativePath: "\(root)/\(skillID)/\(file.relativePath)",
                        content: file.content,
                        source: .generated
                    ))
                }
            }
        }

        return artifacts.sorted { $0.relativePath < $1.relativePath }
    }

    static func resolveClaudeCodePluginArtifacts(
        serviceID: String,
        resolvedConnections: AIBDeployResolvedConnections,
        skillArtifacts: [AIBDeployArtifact]
    ) throws -> [AIBDeployArtifact] {
        let template = ClaudeCodePluginTemplate(
            serviceID: serviceID,
            servers: resolvedConnections.mcpServers.map { target in
                let serviceRef = URL(string: target.serviceRef) == nil ? target.serviceRef : nil
                return .init(
                    name: ClaudeCodePluginBundle.mcpServerName(
                        serviceRef: serviceRef,
                        resolvedURL: target.resolvedURL
                    ),
                    serviceRef: serviceRef,
                    source: serviceRef == nil ? "url" : "service_ref"
                )
            }
        )
        let binding = ClaudeCodePluginBinding(
            serviceID: serviceID,
            servers: resolvedConnections.mcpServers.map { target in
                let serviceRef = URL(string: target.serviceRef) == nil ? target.serviceRef : nil
                return .init(
                    name: ClaudeCodePluginBundle.mcpServerName(
                        serviceRef: serviceRef,
                        resolvedURL: target.resolvedURL
                    ),
                    resolvedURL: target.resolvedURL
                )
            }
        )
        let rendered = try ClaudeCodePluginBundle.render(template: template, binding: binding)

        let pluginFiles = rendered.files.map {
            AIBDeployArtifact(
                relativePath: $0.relativePath,
                content: $0.content,
                source: .generated
            )
        }
        return (pluginFiles + skillArtifacts)
            .sorted { $0.relativePath < $1.relativePath }
    }

    static func resolveExecutionDirectoryArtifacts(
        executionRootPath: String
    ) throws -> [AIBDeployArtifact] {
        let executionRootURL = URL(fileURLWithPath: executionRootPath)
        let files = try AIBExecutionDirectoryInspector.collectFiles(at: executionRootURL)

        return try files.map { file in
            AIBDeployArtifact(
                relativePath: try projectedExecutionDirectoryRelativePath(for: file.relativePath),
                content: file.content,
                source: .generated
            )
        }
        .sorted { $0.relativePath < $1.relativePath }
    }

    static func projectedExecutionDirectoryRelativePath(for relativePath: String) throws -> String {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let head = parts.first else {
            throw AIBDeployError(
                phase: "plan",
                message: "Execution directory artifact path is empty"
            )
        }

        let tail = parts.dropFirst().joined(separator: "/")
        switch head {
        case ".claude":
            return tail.isEmpty ? "__aib_deploy/claude" : "__aib_deploy/claude/\(tail)"
        case ".codex":
            return tail.isEmpty ? "__aib_deploy/codex" : "__aib_deploy/codex/\(tail)"
        case ".agents":
            return tail.isEmpty ? "__aib_deploy/agents" : "__aib_deploy/agents/\(tail)"
        case "AGENTS.md", "AGENT.md", "CLAUDE.md", "CODEX.md":
            return "__aib_deploy/root/\(head)"
        default:
            throw AIBDeployError(
                phase: "plan",
                message: "Unsupported execution directory artifact: \(relativePath)"
            )
        }
    }
}

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
