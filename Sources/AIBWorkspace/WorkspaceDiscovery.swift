import Foundation

public enum WorkspaceDiscovery {
    public static let defaultManifestCandidates = [".aib/services.yaml", "aib.services.yaml"]
    private static let excludedDirectoryNames: Set<String> = [
        ".git", "node_modules", ".build", ".swiftpm", "dist", "build", ".next", ".turbo", ".venv", "__pycache__"
    ]

    public static func discoverRepos(workspaceRoot: String, scanPath: String) throws -> [WorkspaceRepo] {
        let fm = FileManager.default
        let rootURL = URL(fileURLWithPath: workspaceRoot).standardizedFileURL
        let scanURL = URL(fileURLWithPath: scanPath, relativeTo: rootURL).standardizedFileURL

        var repos: [DiscoveredRepo] = []
        let enumerator = fm.enumerator(
            at: scanURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .nameKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        )

        while let url = enumerator?.nextObject() as? URL {
            let last = url.lastPathComponent
            if excludedDirectoryNames.contains(last) {
                enumerator?.skipDescendants()
                continue
            }
            let gitDir = url.appendingPathComponent(".git")
            if fm.fileExists(atPath: gitDir.path) {
                repos.append(try inspectRepo(at: url, workspaceRoot: rootURL))
                enumerator?.skipDescendants()
            }
        }

        let uniqueNamed = uniquedRepoNames(for: repos)
        return uniqueNamed.map { $0.repo }.sorted { $0.name < $1.name }
    }

    private static func inspectRepo(at repoURL: URL, workspaceRoot: URL) throws -> DiscoveredRepo {
        let fm = FileManager.default
        let manifestPath = defaultManifestCandidates.first { candidate in
            fm.fileExists(atPath: repoURL.appendingPathComponent(candidate).path)
        }

        let runtimeInfo = detectRuntimeInfo(repoURL: repoURL)
        let relPath = relativePath(from: workspaceRoot, to: repoURL)

        var status: RepoStatus = .discoverable
        var confidence: DetectionConfidence = runtimeInfo.confidence
        if manifestPath != nil {
            status = .managed
            confidence = .high
        } else if runtimeInfo.candidates.isEmpty {
            status = .unresolved
        }

            let autoSelected = runtimeInfo.candidates.first?.argv.contains("${PORT}") == true
                ? nil
                : runtimeInfo.candidates.first?.argv

            return DiscoveredRepo(
                repo: WorkspaceRepo(
                name: repoURL.lastPathComponent,
                path: relPath,
                manifestPath: manifestPath,
                runtime: runtimeInfo.runtime,
                framework: runtimeInfo.framework,
                packageManager: runtimeInfo.packageManager,
                status: status,
                detectionConfidence: confidence,
                commandCandidates: runtimeInfo.candidates,
                selectedCommand: autoSelected,
                servicesNamespace: repoURL.lastPathComponent,
                enabled: true
            ),
            originalURL: repoURL
        )
    }

    private static func detectRuntimeInfo(repoURL: URL) -> RuntimeDetection {
        let fm = FileManager.default
        if fm.fileExists(atPath: repoURL.appendingPathComponent("Package.swift").path) {
            return detectSwift(repoURL: repoURL)
        }
        if fm.fileExists(atPath: repoURL.appendingPathComponent("package.json").path) {
            return detectNode(repoURL: repoURL)
        }
        if fm.fileExists(atPath: repoURL.appendingPathComponent("deno.json").path) || fm.fileExists(atPath: repoURL.appendingPathComponent("deno.jsonc").path) {
            return detectDeno(repoURL: repoURL)
        }
        if fm.fileExists(atPath: repoURL.appendingPathComponent("pyproject.toml").path)
            || fm.fileExists(atPath: repoURL.appendingPathComponent("requirements.txt").path)
            || fm.fileExists(atPath: repoURL.appendingPathComponent("uv.lock").path)
            || fm.fileExists(atPath: repoURL.appendingPathComponent("poetry.lock").path)
        {
            return detectPython(repoURL: repoURL)
        }
        return RuntimeDetection(runtime: .unknown, framework: .unknown, packageManager: .unknown, confidence: .low, candidates: [])
    }

    private static func detectSwift(repoURL: URL) -> RuntimeDetection {
        let packagePath = repoURL.appendingPathComponent("Package.swift").path
        let content = readTextFileOrEmpty(path: packagePath)
        let framework: FrameworkKind
        if content.localizedCaseInsensitiveContains("vapor") {
            framework = .vapor
        } else if content.localizedCaseInsensitiveContains("hummingbird") {
            framework = .hummingbird
        } else {
            framework = .plain
        }
        let candidates = [CommandCandidate(argv: ["swift", "run"], reason: "SwiftPM repository")]
        return RuntimeDetection(runtime: .swift, framework: framework, packageManager: .swiftpm, confidence: .medium, candidates: candidates)
    }

    private static func detectNode(repoURL: URL) -> RuntimeDetection {
        let packagePath = repoURL.appendingPathComponent("package.json")
        var scripts: [String: String] = [:]
        var deps = Set<String>()
        do {
            let data = try Data(contentsOf: packagePath)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let scriptsJSON = json["scripts"] as? [String: String] {
                    scripts = scriptsJSON
                }
                if let dependencies = json["dependencies"] as? [String: Any] {
                    deps.formUnion(dependencies.keys)
                }
                if let devDependencies = json["devDependencies"] as? [String: Any] {
                    deps.formUnion(devDependencies.keys)
                }
            }
        } catch {
            // Best-effort detection only.
        }

        let framework: FrameworkKind
        if deps.contains("express") {
            framework = .express
        } else if deps.contains("fastify") {
            framework = .fastify
        } else if deps.contains("@nestjs/core") {
            framework = .nestjs
        } else if deps.contains("next") {
            framework = .nextjs
        } else if deps.contains("hono") {
            framework = .hono
        } else {
            framework = .plain
        }

        let packageManager: PackageManagerKind = {
            let fm = FileManager.default
            if fm.fileExists(atPath: repoURL.appendingPathComponent("pnpm-lock.yaml").path) { return .pnpm }
            if fm.fileExists(atPath: repoURL.appendingPathComponent("yarn.lock").path) { return .yarn }
            return .npm
        }()

        let candidates = nodeCandidates(packageManager: packageManager, scripts: scripts)
        let confidence: DetectionConfidence = candidates.isEmpty ? .low : .medium
        return RuntimeDetection(runtime: .node, framework: framework, packageManager: packageManager, confidence: confidence, candidates: candidates)
    }

    private static func nodeCandidates(packageManager: PackageManagerKind, scripts: [String: String]) -> [CommandCandidate] {
        var result: [CommandCandidate] = []
        let preferred = ["dev", "start"]
        for script in preferred where scripts[script] != nil {
            if packageManager == .yarn {
                result.append(.init(argv: ["yarn", script], reason: "package.json scripts.\(script)"))
            } else if packageManager == .pnpm {
                result.append(.init(argv: ["pnpm", script], reason: "package.json scripts.\(script)"))
            } else {
                result.append(.init(argv: ["npm", "run", script], reason: "package.json scripts.\(script)"))
            }
        }
        if result.isEmpty, !scripts.isEmpty {
            if let first = scripts.keys.sorted().first {
                if packageManager == .yarn {
                    result.append(.init(argv: ["yarn", first], reason: "package.json first script"))
                } else if packageManager == .pnpm {
                    result.append(.init(argv: ["pnpm", first], reason: "package.json first script"))
                } else {
                    result.append(.init(argv: ["npm", "run", first], reason: "package.json first script"))
                }
            }
        }
        return result
    }

    private static func detectDeno(repoURL: URL) -> RuntimeDetection {
        let denoJSONPath = FileManager.default.fileExists(atPath: repoURL.appendingPathComponent("deno.json").path)
            ? repoURL.appendingPathComponent("deno.json")
            : repoURL.appendingPathComponent("deno.jsonc")
        let text = readTextFileOrEmpty(url: denoJSONPath)
        let framework: FrameworkKind
        if text.localizedCaseInsensitiveContains("fresh") {
            framework = .fresh
        } else if text.localizedCaseInsensitiveContains("hono") {
            framework = .hono
        } else if text.localizedCaseInsensitiveContains("oak") {
            framework = .oak
        } else {
            framework = .plain
        }

        var candidates: [CommandCandidate] = []
        if text.contains("\"dev\"") || text.contains("dev:") {
            candidates.append(.init(argv: ["deno", "task", "dev"], reason: "deno task dev"))
        }
        return RuntimeDetection(runtime: .deno, framework: framework, packageManager: .deno, confidence: candidates.isEmpty ? .low : .medium, candidates: candidates)
    }

    private static func detectPython(repoURL: URL) -> RuntimeDetection {
        let fm = FileManager.default
        let pyprojectPath = repoURL.appendingPathComponent("pyproject.toml")
        let text: String = {
            if fm.fileExists(atPath: pyprojectPath.path) {
                return readTextFileOrEmpty(url: pyprojectPath)
            }
            return ""
        }()

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

        let packageManager: PackageManagerKind = {
            if fm.fileExists(atPath: repoURL.appendingPathComponent("uv.lock").path) { return .uv }
            if fm.fileExists(atPath: repoURL.appendingPathComponent("poetry.lock").path) { return .poetry }
            return .pip
        }()

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
        return RuntimeDetection(runtime: .python, framework: framework, packageManager: packageManager, confidence: confidence, candidates: candidates)
    }

    private static func uniquedRepoNames(for repos: [DiscoveredRepo]) -> [DiscoveredRepo] {
        var seen: [String: Int] = [:]
        var result: [DiscoveredRepo] = []
        for item in repos.sorted(by: { $0.repo.name < $1.repo.name }) {
            var adjusted = item
            let base = item.repo.name
            let count = (seen[base] ?? 0) + 1
            seen[base] = count
            if count > 1 {
                adjusted.repo.name = "\(base)-\(count)"
                if adjusted.repo.servicesNamespace == base {
                    adjusted.repo.servicesNamespace = adjusted.repo.name
                }
            }
            result.append(adjusted)
        }
        return result
    }

    private static func relativePath(from root: URL, to target: URL) -> String {
        let rootComps = root.standardizedFileURL.pathComponents
        let targetComps = target.standardizedFileURL.pathComponents
        var i = 0
        while i < min(rootComps.count, targetComps.count), rootComps[i] == targetComps[i] {
            i += 1
        }
        let upward = Array(repeating: "..", count: rootComps.count - i)
        let downward = Array(targetComps[i...])
        let comps = upward + downward
        return comps.isEmpty ? "." : comps.joined(separator: "/")
    }
}

private func readTextFileOrEmpty(path: String) -> String {
    do {
        return try String(contentsOfFile: path, encoding: .utf8)
    } catch {
        return ""
    }
}

private func readTextFileOrEmpty(url: URL) -> String {
    do {
        return try String(contentsOf: url, encoding: .utf8)
    } catch {
        return ""
    }
}

private struct RuntimeDetection {
    var runtime: RuntimeKind
    var framework: FrameworkKind
    var packageManager: PackageManagerKind
    var confidence: DetectionConfidence
    var candidates: [CommandCandidate]
}

private struct DiscoveredRepo {
    var repo: WorkspaceRepo
    var originalURL: URL
}
