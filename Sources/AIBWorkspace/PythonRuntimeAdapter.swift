import AIBConfig
import AIBRuntimeCore
import Foundation

public struct PythonRuntimeAdapter: RuntimeAdapter, Sendable {
    public var runtimeKind: RuntimeKind { .python }

    public init() {}

    public func canHandle(repoURL: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: repoURL.appendingPathComponent("pyproject.toml").path)
            || fm.fileExists(atPath: repoURL.appendingPathComponent("requirements.txt").path)
            || fm.fileExists(atPath: repoURL.appendingPathComponent("uv.lock").path)
            || fm.fileExists(atPath: repoURL.appendingPathComponent("poetry.lock").path)
    }

    public func detect(repoURL: URL) -> RuntimeDetectionResult {
        let fm = FileManager.default
        let pyprojectPath = repoURL.appendingPathComponent("pyproject.toml")
        let text: String = fm.fileExists(atPath: pyprojectPath.path) ? readTextFileOrEmpty(url: pyprojectPath) : ""

        let framework: FrameworkKind
        if text.localizedCaseInsensitiveContains("fastapi") {
            framework = .fastapi
        } else if text.localizedCaseInsensitiveContains("django") {
            framework = .django
        } else if text.localizedCaseInsensitiveContains("flask") {
            framework = .flask
        } else if text.localizedCaseInsensitiveContains("starlette") {
            framework = .starlette
        } else {
            framework = .plain
        }

        let packageManager = detectPackageManager(repoURL: repoURL)

        var candidates: [CommandCandidate] = []
        switch framework {
        case .fastapi, .starlette:
            if packageManager == .uv {
                candidates.append(.init(argv: ["uv", "run", "uvicorn", "app:app", "--host", "127.0.0.1", "--port", "${PORT}", "--reload"], reason: "FastAPI/Starlette heuristic"))
            } else {
                candidates.append(.init(argv: ["python", "-m", "uvicorn", "app:app", "--host", "127.0.0.1", "--port", "${PORT}", "--reload"], reason: "FastAPI/Starlette heuristic"))
            }
        case .django:
            candidates.append(.init(argv: ["python", "manage.py", "runserver", "127.0.0.1:${PORT}"], reason: "Django heuristic"))
        case .flask:
            candidates.append(.init(argv: ["python", "-m", "flask", "run", "--host", "127.0.0.1", "--port", "${PORT}"], reason: "Flask heuristic"))
        default:
            break
        }

        let confidence: DetectionConfidence = candidates.isEmpty ? .low : .medium
        return RuntimeDetectionResult(
            runtime: .python,
            framework: framework,
            packageManager: packageManager,
            confidence: confidence,
            candidates: candidates
        )
    }

    public func defaults(packageManager: PackageManagerKind) -> RuntimeDefaults {
        let installCommand: [String]?
        switch packageManager {
        case .uv: installCommand = ["uv", "sync"]
        case .poetry: installCommand = ["poetry", "install"]
        case .pip: installCommand = nil
        default: installCommand = nil
        }
        return RuntimeDefaults(
            watchMode: .internal,
            buildCommand: nil,
            installCommand: installCommand,
            watchPaths: ["pyproject.toml", "requirements.txt", "uv.lock", "poetry.lock"],
            serviceKind: .agent
        )
    }

    private func detectPackageManager(repoURL: URL) -> PackageManagerKind {
        let fm = FileManager.default
        if fm.fileExists(atPath: repoURL.appendingPathComponent("uv.lock").path) { return .uv }
        if fm.fileExists(atPath: repoURL.appendingPathComponent("poetry.lock").path) { return .poetry }
        return .pip
    }
}
