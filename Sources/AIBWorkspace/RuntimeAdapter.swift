import AIBConfig
import AIBRuntimeCore
import Foundation

// MARK: - Protocol

public protocol RuntimeAdapter: Sendable {
    var runtimeKind: RuntimeKind { get }
    func canHandle(repoURL: URL) -> Bool
    func detect(repoURL: URL) -> RuntimeDetectionResult
    func defaults(packageManager: PackageManagerKind) -> RuntimeDefaults
}

// MARK: - Detection Result

public struct RuntimeDetectionResult: Sendable, Equatable {
    public var runtime: RuntimeKind
    public var framework: FrameworkKind
    public var packageManager: PackageManagerKind
    public var confidence: DetectionConfidence
    public var candidates: [CommandCandidate]

    /// Deployable service names extracted from the package manifest.
    /// - Node: `package.json` `"name"` (single element)
    /// - Swift: `.executableTarget` names from `Package.swift` (may be multiple)
    /// - Python: `pyproject.toml` `[project].name` (single element)
    /// - Deno: `deno.json` `"name"` (single element)
    /// Empty if the name could not be determined (caller falls back to directory name).
    public var serviceNames: [String]

    /// Suggested service kind inferred from package dependencies.
    /// MCP SDK presence → `.mcp`, otherwise falls back to runtime default.
    public var suggestedServiceKind: ServiceKind

    public init(
        runtime: RuntimeKind,
        framework: FrameworkKind,
        packageManager: PackageManagerKind,
        confidence: DetectionConfidence,
        candidates: [CommandCandidate],
        serviceNames: [String] = [],
        suggestedServiceKind: ServiceKind = .unknown
    ) {
        self.runtime = runtime
        self.framework = framework
        self.packageManager = packageManager
        self.confidence = confidence
        self.candidates = candidates
        self.serviceNames = serviceNames
        self.suggestedServiceKind = suggestedServiceKind
    }

    public static let unknown = RuntimeDetectionResult(
        runtime: .unknown,
        framework: .unknown,
        packageManager: .unknown,
        confidence: .low,
        candidates: []
    )
}

// MARK: - Defaults

public struct RuntimeDefaults: Sendable, Equatable {
    public var watchMode: WatchMode
    public var buildCommand: [String]?
    public var installCommand: [String]?
    public var watchPaths: [String]
    public var serviceKind: ServiceKind

    public init(
        watchMode: WatchMode,
        buildCommand: [String]? = nil,
        installCommand: [String]? = nil,
        watchPaths: [String],
        serviceKind: ServiceKind
    ) {
        self.watchMode = watchMode
        self.buildCommand = buildCommand
        self.installCommand = installCommand
        self.watchPaths = watchPaths
        self.serviceKind = serviceKind
    }
}
