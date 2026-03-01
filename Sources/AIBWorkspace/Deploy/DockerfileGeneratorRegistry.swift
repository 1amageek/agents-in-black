import AIBRuntimeCore
import Foundation

/// Registry of Dockerfile generators, one per runtime.
public enum DockerfileGeneratorRegistry {

    public static let generators: [any DockerfileGenerator] = [
        SwiftDockerfileGenerator(),
        NodeDockerfileGenerator(),
        PythonDockerfileGenerator(),
        DenoDockerfileGenerator(),
    ]

    /// Find a generator for the given runtime kind.
    public static func generator(for runtime: RuntimeKind) -> (any DockerfileGenerator)? {
        generators.first { $0.runtimeKind == runtime }
    }
}
