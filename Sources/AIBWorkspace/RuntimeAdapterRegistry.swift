import AIBConfig
import AIBRuntimeCore
import Foundation

public enum RuntimeAdapterRegistry {
    public static let adapters: [any RuntimeAdapter] = [
        SwiftRuntimeAdapter(),
        NodeRuntimeAdapter(),
        DenoRuntimeAdapter(),
        PythonRuntimeAdapter(),
    ]

    public static func detect(repoURL: URL) -> RuntimeDetectionResult {
        for adapter in adapters {
            if adapter.canHandle(repoURL: repoURL) {
                return adapter.detect(repoURL: repoURL)
            }
        }
        return .unknown
    }

    public static func detectAll(repoURL: URL) -> [RuntimeDetectionResult] {
        adapters.compactMap { adapter in
            adapter.canHandle(repoURL: repoURL) ? adapter.detect(repoURL: repoURL) : nil
        }
    }

    public static func defaults(for runtime: RuntimeKind, packageManager: PackageManagerKind) -> RuntimeDefaults {
        for adapter in adapters where adapter.runtimeKind == runtime {
            return adapter.defaults(packageManager: packageManager)
        }
        return RuntimeDefaults(
            watchMode: .external,
            buildCommand: nil,
            installCommand: nil,
            watchPaths: [],
            serviceKind: .unknown
        )
    }
}
