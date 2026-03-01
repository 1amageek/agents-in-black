import AIBConfig
import AIBRuntimeCore
import Foundation

/// Protocol for generating Dockerfiles based on runtime type.
public protocol DockerfileGenerator: Sendable {
    var runtimeKind: RuntimeKind { get }

    /// Generate Dockerfile content for the given service.
    /// - Parameters:
    ///   - servicePath: Path to the service directory for inspecting project files.
    ///   - runCommand: The command used to run the service.
    ///   - buildCommand: Optional build command override.
    ///   - installCommand: Optional install command override.
    ///   - port: The port to expose.
    func generate(
        servicePath: URL,
        runCommand: [String],
        buildCommand: [String]?,
        installCommand: [String]?,
        port: Int
    ) -> String
}
