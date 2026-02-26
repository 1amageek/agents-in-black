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
        var mounts = Set<String>()

        for service in config.services {
            if !ids.insert(service.id).inserted {
                result.errors.append("duplicate service id: \(service.id)")
            }
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

        return result
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
