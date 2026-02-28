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

    public init(
        runtime: RuntimeKind,
        framework: FrameworkKind,
        packageManager: PackageManagerKind,
        confidence: DetectionConfidence,
        candidates: [CommandCandidate]
    ) {
        self.runtime = runtime
        self.framework = framework
        self.packageManager = packageManager
        self.confidence = confidence
        self.candidates = candidates
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
