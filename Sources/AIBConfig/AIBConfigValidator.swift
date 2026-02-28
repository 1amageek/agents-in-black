import AIBRuntimeCore
import Foundation

public struct ValidationResult: Sendable {
    public var errors: [String]
    public var warnings: [String]

    public init(errors: [String] = [], warnings: [String] = []) {
        self.errors = errors
        self.warnings = warnings
    }
}

public enum AIBConfigValidator {
    public static func validate(_ config: AIBConfig) throws -> ValidationResult {
        var result = ValidationResult()

        if config.gateway.websocket.enabled {
            result.errors.append("gateway.websocket.enabled=true is unsupported in v1")
        }

        if config.gateway.port < 1 || config.gateway.port > 65535 {
            result.errors.append("gateway.port must be 1...65535")
        }

        do {
            _ = try config.gateway.timeouts.header.parse()
            _ = try config.gateway.timeouts.backendConnect.parse()
            _ = try config.gateway.timeouts.backendResponseHeader.parse()
            _ = try config.gateway.timeouts.idle.parse()
            _ = try config.gateway.timeouts.request.parse()
        } catch {
            result.errors.append("gateway timeouts contain invalid duration: \(error)")
        }

        var ids = Set<ServiceID>()
        var servicesByID: [ServiceID: ServiceConfig] = [:]
        var mounts = Set<String>()

        for service in config.services {
            if !ids.insert(service.id).inserted {
                result.errors.append("duplicate service id: \(service.id)")
            }
            servicesByID[service.id] = service
            if !mounts.insert(service.mountPath).inserted {
                result.errors.append("duplicate mount_path: \(service.mountPath)")
            }

            validateMountPath(service.mountPath, errors: &result.errors)

            if service.port != 0 && !(1024 ... 65535).contains(service.port) {
                result.errors.append("service \(service.id): port must be 0 or 1024...65535")
            }
            if service.run.isEmpty {
                result.errors.append("service \(service.id): run must not be empty")
            }
            if let build = service.build, build.isEmpty {
                result.errors.append("service \(service.id): build must not be empty when present")
            }
            if let install = service.install, install.isEmpty {
                result.errors.append("service \(service.id): install must not be empty when present")
            }
            if service.concurrency.maxInflight <= 0 {
                result.errors.append("service \(service.id): concurrency.max_inflight must be > 0")
            }
            if service.concurrency.overflowMode == .queue {
                result.errors.append("service \(service.id): overflow_mode=queue is unsupported in v1")
            }
            if service.auth.mode != .off {
                result.errors.append("service \(service.id): auth.mode=\(service.auth.mode.rawValue) is unsupported in v1")
            }
            if service.kind != .agent,
               (!service.connections.mcpServers.isEmpty || !service.connections.a2aAgents.isEmpty)
            {
                result.errors.append("service \(service.id): only kind=agent can declare connections")
            }
            if service.watchMode == .external && service.watchPaths.isEmpty {
                result.warnings.append("service \(service.id): watch_mode=external but watch_paths is empty")
            }
            if service.watchMode == .internal && (service.build != nil || service.install != nil) {
                result.warnings.append("service \(service.id): watch_mode=internal with build/install set")
            }
            do {
                _ = try service.health.startupReadyTimeout.parse()
                _ = try service.health.checkInterval.parse()
                _ = try service.restart.drainTimeout.parse()
                _ = try service.restart.shutdownGracePeriod.parse()
                _ = try service.restart.backoffInitial.parse()
                _ = try service.restart.backoffMax.parse()
                if let queueTimeout = service.concurrency.queueTimeout {
                    _ = try queueTimeout.parse()
                }
            } catch {
                result.errors.append("service \(service.id): invalid duration: \(error)")
            }
            if service.health.failureThreshold <= 0 {
                result.errors.append("service \(service.id): health.failure_threshold must be > 0")
            }
        }

        validateMountPrefixCollisions(config.services.map(\.mountPath), errors: &result.errors)

        for service in config.services {
            for affected in service.restartAffects where !ids.contains(affected) {
                result.errors.append("service \(service.id): restart_affects contains unknown service \(affected)")
            }
        }

        validateConnections(config.services, servicesByID: servicesByID, errors: &result.errors)

        return result
    }

    private static func validateConnections(
        _ services: [ServiceConfig],
        servicesByID: [ServiceID: ServiceConfig],
        errors: inout [String]
    ) {
        for service in services {
            var seenTargets: Set<String> = []
            for target in service.connections.mcpServers {
                validateConnectionTarget(
                    sourceService: service,
                    target: target,
                    group: "mcp_servers",
                    expectedTargetKind: .mcp,
                    servicesByID: servicesByID,
                    seenTargets: &seenTargets,
                    errors: &errors
                )
            }
            for target in service.connections.a2aAgents {
                validateConnectionTarget(
                    sourceService: service,
                    target: target,
                    group: "a2a_agents",
                    expectedTargetKind: .agent,
                    servicesByID: servicesByID,
                    seenTargets: &seenTargets,
                    errors: &errors
                )
            }
        }
    }

    private static func validateConnectionTarget(
        sourceService: ServiceConfig,
        target: ServiceConnectionTarget,
        group: String,
        expectedTargetKind: ServiceKind,
        servicesByID: [ServiceID: ServiceConfig],
        seenTargets: inout Set<String>,
        errors: inout [String]
    ) {
        let serviceRef = target.serviceRef?.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = target.url?.trimmingCharacters(in: .whitespacesAndNewlines)

        if serviceRef == nil || serviceRef?.isEmpty == true {
            if url == nil || url?.isEmpty == true {
                errors.append("service \(sourceService.id): \(group) target must set either service_ref or url")
                return
            }
            if !isValidURL(url!) {
                errors.append("service \(sourceService.id): \(group) has invalid url '\(url!)'")
                return
            }
            let key = "\(group):url:\(url!)"
            if !seenTargets.insert(key).inserted {
                errors.append("service \(sourceService.id): duplicate \(group) target '\(url!)'")
            }
            return
        }

        if url != nil && url?.isEmpty == false {
            errors.append("service \(sourceService.id): \(group) target cannot set both service_ref and url")
            return
        }

        guard let resolvedRef = serviceRef, !resolvedRef.isEmpty else {
            errors.append("service \(sourceService.id): \(group) has empty service_ref")
            return
        }

        let targetID = ServiceID(resolvedRef)
        if targetID == sourceService.id {
            errors.append("service \(sourceService.id): \(group) cannot reference itself")
        }
        guard let resolved = servicesByID[targetID] else {
            errors.append("service \(sourceService.id): \(group) references unknown service \(targetID)")
            return
        }
        if resolved.kind != expectedTargetKind {
            errors.append(
                "service \(sourceService.id): \(group) target \(targetID) must be kind=\(expectedTargetKind.rawValue), got \(resolved.kind.rawValue)"
            )
        }

        let key = "\(group):ref:\(targetID.rawValue)"
        if !seenTargets.insert(key).inserted {
            errors.append("service \(sourceService.id): duplicate \(group) target '\(targetID)'")
        }
    }

    private static func isValidURL(_ value: String) -> Bool {
        guard let url = URL(string: value) else { return false }
        return url.scheme?.isEmpty == false && url.host?.isEmpty == false
    }

    private static func validateMountPath(_ mountPath: String, errors: inout [String]) {
        if mountPath == "/" {
            errors.append("mount_path '/' is not allowed in v1")
            return
        }
        if !mountPath.hasPrefix("/") {
            errors.append("mount_path must start with '/': \(mountPath)")
        }
        if mountPath.count > 1 && mountPath.hasSuffix("/") {
            errors.append("mount_path must not end with '/': \(mountPath)")
        }
        if mountPath.contains("..") {
            errors.append("mount_path must not contain '..': \(mountPath)")
        }
    }

    private static func validateMountPrefixCollisions(_ mountPaths: [String], errors: inout [String]) {
        let sorted = mountPaths.sorted()
        for i in 0 ..< sorted.count {
            for j in (i + 1) ..< sorted.count {
                let a = sorted[i]
                let b = sorted[j]
                if b.hasPrefix(a + "/") {
                    errors.append("mount_path prefix collision: \(a) and \(b)")
                }
            }
        }
    }
}
